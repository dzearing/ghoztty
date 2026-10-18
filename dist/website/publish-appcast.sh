#!/usr/bin/env bash
#
# Add a macOS release to the Sparkle appcast and push it to gh-pages (T1089).
#
# This is the macOS twin of publish-windows-links.sh, and it is a script for
# the same reason that one is (T353): the gh-pages branch has two writers on
# one tag push -- this appcast update from release.yml, and the website's
# Windows links from release-windows.yml -- so whichever pushes second is
# rejected and lives or dies by the rebase-retry at the bottom. Inline in YAML
# that retry ran only during a real release, and only when it lost the race.
# Losing it here is worse than losing it there: an appcast that never lands
# means installed Macs never see the update. As a file it runs against a bare
# repo on disk with the website push staged as the rival, which is section H
# of test\win32\website-windows-download.ps1.
#
# Usage:
#   publish-appcast.sh <gh-pages-repo-url> <X.Y.Z> <download-url> \
#                      <ed-signature> <length> [client-notes.json] [workdir]
#
# `workdir` defaults to a fresh mktemp -d; when it is given it is REPLACED, so
# a re-run in CI's fixed /tmp/gh-pages cannot half-reuse a previous clone.
#
# Environment:
#   PYTHON                 interpreter for update-appcast.py (default python3).
#   APPCAST_PUB_DATE       the item's pubDate (default: now, RFC 2822, UTC).
#   APPCAST_PUSH_ATTEMPTS  how many times to try the push (default 5).
#   APPCAST_PUSH_BACKOFF   seconds multiplied by the attempt number between
#                          tries (default 3; the harness sets 0).
#
# Exit codes: 0 pushed, or already current. 1 could not push / rebase failed.
# 2 called wrong -- including an EMPTY signature, which is what a sign step
# that printed nothing produces: Sparkle refuses an update whose edSignature
# does not verify, so publishing one would offer every installed Mac an
# update it cannot install. Anything update-appcast.py exits is propagated.
set -uo pipefail

REPO_URL="${1:-}"
VERSION="${2:-}"
DOWNLOAD_URL="${3:-}"
ED_SIGNATURE="${4:-}"
LENGTH="${5:-}"
CLIENT_NOTES="${6:-}"
WORKDIR="${7:-}"

usage() {
    echo "usage: publish-appcast.sh <gh-pages-repo-url> <X.Y.Z> <download-url> <ed-signature> <length> [client-notes.json] [workdir]" >&2
    exit 2
}

if [ -z "$REPO_URL" ] || [ -z "$VERSION" ] || [ -z "$DOWNLOAD_URL" ] || [ -z "$LENGTH" ]; then
    usage
fi
if [ -z "$ED_SIGNATURE" ]; then
    echo "::error::no Sparkle edSignature for v${VERSION} -- installed Macs would reject this update" >&2
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON:-python3}"
ATTEMPTS="${APPCAST_PUSH_ATTEMPTS:-5}"
BACKOFF="${APPCAST_PUSH_BACKOFF:-3}"
PUB_DATE="${APPCAST_PUB_DATE:-$(date -u '+%a, %d %b %Y %H:%M:%S %z')}"

if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d)"
else
    rm -rf "$WORKDIR"
fi

git clone --branch gh-pages --single-branch "$REPO_URL" "$WORKDIR" || exit 1

"$PY" "$SCRIPT_DIR/update-appcast.py" "$WORKDIR/appcast.xml" "$VERSION" \
    "$DOWNLOAD_URL" "$ED_SIGNATURE" "$LENGTH" "$PUB_DATE" "$CLIENT_NOTES"
rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi

cd "$WORKDIR" || exit 1

# A re-run whose appcast edit is byte-identical has nothing to commit, and
# `git commit` exits non-zero on that -- which would fail a release that is
# already fully published.
if git diff --quiet -- appcast.xml; then
    echo "appcast already up to date for v${VERSION}"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add appcast.xml
git commit -m "Update appcast for v${VERSION}" || exit 1

# release-windows.yml writes index.html on this same branch from the same tag
# push (T39), and a human can push the website version bump at any time. Rebase
# and retry rather than failing the job after the release is already public.
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    if git push origin gh-pages; then
        echo "appcast pushed (attempt $attempt)"
        exit 0
    fi
    echo "::warning::gh-pages push rejected (attempt $attempt); rebasing"
    if ! git pull --rebase origin gh-pages; then
        echo "::error::rebase onto origin/gh-pages failed (attempt $attempt)" >&2
        exit 1
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ] && [ "$BACKOFF" -gt 0 ]; then
        sleep $(( attempt * BACKOFF ))
    fi
    attempt=$(( attempt + 1 ))
done

echo "::error::could not push the appcast to gh-pages after $ATTEMPTS attempts"
exit 1
