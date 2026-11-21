#!/usr/bin/env bash
# clone-retry.sh -- clone a pinned tag from the first of several sources that
# answers, with retries and backoff, and refuse a clone whose commit is not
# the pinned one (T1582).
#
# Sourced, not run: install-msitools.sh is the caller, and
# test/win32/release-artifacts.ps1 (section E13) sources it on its own to drive
# it against local repositories, so the retry and fallback paths are exercised
# without a network.
#
# Why it exists: the msitools build used to be ONE unguarded
# `git clone https://gitlab.gnome.org/...`. A host we do not run answering 503
# for a minute (2026-09-15, 2026-09-24, 2026-10-13) failed fork-ci's
# windows-cross job with exit 128, turned the branch head red, and made the
# next turn's validate gate a judgement call (-NoCiCheck) instead of a gate.
#
# Why the commit pin: a fallback source is a second party we trust to serve the
# same bytes. Checking that the tag resolves to the commit we expect makes that
# trust checkable -- a mirror that drifted, or a tag that was moved, fails
# loudly here instead of building something else under the same version.
#
# Usage:
#   clone_pinned_tag <dest> <tag> <expected-commit-sha> <url> [<url> ...]
# Knobs (for tests): CLONE_RETRY_ATTEMPTS (default 3 per source),
# CLONE_RETRY_SLEEP (backoff base in seconds, default 10).

clone_pinned_tag() {
  local dest="$1" tag="$2" want="$3"
  shift 3
  local attempts="${CLONE_RETRY_ATTEMPTS:-3}"
  local base="${CLONE_RETRY_SLEEP:-10}"
  local url attempt got

  if [ "$#" -eq 0 ]; then
    echo "::error::clone_pinned_tag: no source urls given" >&2
    return 2
  fi

  for url in "$@"; do
    for attempt in $(seq 1 "$attempts"); do
      rm -rf "$dest"
      echo "cloning $tag from $url (attempt $attempt of $attempts)"
      if git clone --recurse-submodules --shallow-submodules \
          --branch "$tag" "$url" "$dest"; then
        got="$(git -C "$dest" rev-parse HEAD)"
        if [ "$got" = "$want" ]; then
          echo "cloned $tag from $url at $got"
          return 0
        fi
        # A wrong commit is not a network flake: retrying the same source
        # will serve the same bytes, so move straight to the next one.
        echo "::warning::$url serves $tag at $got, expected $want; not using it"
        break
      fi
      if [ "$attempt" -lt "$attempts" ]; then
        echo "clone from $url failed; retrying in $((attempt * base))s"
        sleep $((attempt * base))
      fi
    done
  done

  rm -rf "$dest"
  echo "::error::could not clone $tag at $want from any source: $*" >&2
  return 1
}
