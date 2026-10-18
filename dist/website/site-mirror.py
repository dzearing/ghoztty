#!/usr/bin/env python3
"""Keep relay/deploy/ghpages/index.html in step with the deployed page (T1088).

The in-repo page is a MIRROR of gh-pages, and gh-pages is written by more
than one hand: release.yml bumps the macOS download, and release-windows.yml
retargets the Windows links (update-windows-links.py) on every win-v release
-- daily, since T1220. Nothing writes those stamps back to the branch, so the
mirror falls behind on every release, and test/win32/website-windows-download.ps1
section F used to go red over a difference nobody had to fix by hand. It was
hand-synced three times (T353 found it three releases behind) before this.

So a difference is CLASSIFIED rather than just detected:

  ok       byte-for-byte the same page (line endings aside).
  stamps   the same page apart from release-stamped version numbers. That is
           the normal state between releases, not a defect: `sync` refreshes
           it, and a check that only finds stamps exits 0.
  drift    the page itself differs -- copy, markup, a section added on one
           side only. That IS a defect, and the direction is not knowable
           from the two files: a fix edited into the mirror and never deployed
           looks the same as a hand edit on gh-pages never mirrored. `check`
           exits 1 and names the lines; `sync` refuses without --force, so a
           mirror-side edit is never overwritten by a routine refresh.

A version number is any dotted X.Y.Z, compared after it is masked on both
sides. That is loose on purpose and only safe because it is used to COMPARE,
never to rewrite (update-windows-links.py finds its anchors by element id for
exactly the opposite reason).

  python3 dist/website/site-mirror.py check   [--repo DIR] [--ref REF] [--no-fetch]
  python3 dist/website/site-mirror.py sync    [--repo DIR] [--ref REF] [--no-fetch] [--force]
  python3 dist/website/site-mirror.py compare <mirror.html> <live.html>

Exit codes: 0 ok/stamps (sync: written or nothing to do), 1 drift (sync:
refused), 2 could not answer (no ref, git failed).
"""

import argparse
import os
import re
import subprocess
import sys

MIRROR_PATH = os.path.join("relay", "deploy", "ghpages", "index.html")
DEFAULT_REF = "origin/gh-pages"
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
MAX_SHOWN = 8


def lines_of(text):
    return text.replace("\r\n", "\n").rstrip("\n").split("\n")


def classify(mirror_text, live_text):
    """Return (verdict, details) where verdict is ok | stamps | drift.

    details is a list of (line_no, mirror_line, live_line) for the lines that
    differ -- every differing line for stamps, only the content ones for drift.
    """
    m, l = lines_of(mirror_text), lines_of(live_text)
    if m == l:
        return "ok", []
    n = max(len(m), len(l))
    stamp_lines, content_lines = [], []
    for i in range(n):
        a = m[i] if i < len(m) else None
        b = l[i] if i < len(l) else None
        if a == b:
            continue
        row = (i + 1, a, b)
        if a is not None and b is not None and \
                VERSION_RE.sub("X.Y.Z", a) == VERSION_RE.sub("X.Y.Z", b):
            stamp_lines.append(row)
        else:
            content_lines.append(row)
    if content_lines:
        return "drift", content_lines
    return "stamps", stamp_lines


def versions_in(rows, side):
    seen = []
    for row in rows:
        text = row[side]
        for v in VERSION_RE.findall(text or ""):
            if v not in seen:
                seen.append(v)
    return seen


def report(verdict, rows, label):
    if verdict == "ok":
        print("MIRROR OK {0} matches the deployed page".format(label))
        return
    if verdict == "stamps":
        print("MIRROR STAMPS {0} lags the deployed page by release version "
              "numbers only ({1} line(s): {2} -> {3}); not a defect. Refresh: "
              "python3 dist/website/site-mirror.py sync".format(
                  label, len(rows),
                  ", ".join(versions_in(rows, 1)) or "-",
                  ", ".join(versions_in(rows, 2)) or "-"))
        return
    print("MIRROR DRIFT {0} and the deployed page differ in content "
          "({1} line(s)). Decide which side is right: deploy the mirror's "
          "change to gh-pages, or take the live page with "
          "`python3 dist/website/site-mirror.py sync --force`.".format(
              label, len(rows)))
    for line_no, a, b in rows[:MAX_SHOWN]:
        print("  line {0}:".format(line_no))
        print("    mirror: {0}".format("<eof>" if a is None else a.strip()))
        print("    live  : {0}".format("<eof>" if b is None else b.strip()))
    if len(rows) > MAX_SHOWN:
        print("  ... {0} more".format(len(rows) - MAX_SHOWN))


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def read_live(repo, ref, fetch):
    if fetch and ref.startswith("origin/"):
        # A failed fetch is not fatal: the ref we already have still answers,
        # and a box with no network should report against what it has.
        git(repo, "fetch", "-q", "origin", ref[len("origin/"):])
    p = git(repo, "show", ref + ":index.html")
    if p.returncode != 0:
        sys.stderr.write("site-mirror: cannot read {0}:index.html ({1})\n".format(
            ref, p.stderr.decode("utf-8", "replace").strip()))
        return None
    return p.stdout.decode("utf-8")


def read_file(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def main(argv):
    ap = argparse.ArgumentParser(prog="site-mirror.py")
    ap.add_argument("action", choices=["check", "sync", "compare"])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--ref", default=DEFAULT_REF)
    ap.add_argument("--no-fetch", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args(argv)

    if a.action == "compare":
        if len(a.files) != 2:
            ap.error("compare takes <mirror.html> <live.html>")
        verdict, rows = classify(read_file(a.files[0]), read_file(a.files[1]))
        report(verdict, rows, a.files[0])
        return 1 if verdict == "drift" else 0

    mirror = os.path.join(a.repo, MIRROR_PATH)
    live = read_live(a.repo, a.ref, not a.no_fetch)
    if live is None:
        return 2
    verdict, rows = classify(read_file(mirror), live)
    report(verdict, rows, MIRROR_PATH.replace(os.sep, "/"))

    if a.action == "check":
        return 1 if verdict == "drift" else 0

    # sync
    if verdict == "ok":
        print("SYNC nothing to do")
        return 0
    if verdict == "drift" and not a.force:
        print("SYNC REFUSED the difference is content, not stamps; "
              "re-run with --force once the live page is the right one")
        return 1
    # Written with LF: the mirror is stored LF in the index, and a CRLF write
    # on Windows would only be normalised back by git anyway.
    with open(mirror, "w", encoding="utf-8", newline="\n") as f:
        f.write(live.replace("\r\n", "\n"))
    after, _ = classify(read_file(mirror), live)
    if after != "ok":
        print("SYNC FAILED the mirror still differs after the write")
        return 2
    print("SYNC WROTE {0} from {1} ({2}); commit it".format(
        MIRROR_PATH.replace(os.sep, "/"), a.ref, verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
