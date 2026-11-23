#!/usr/bin/env bash
# viewer-composer.sh - L9j-2 (T3544) acceptance: the GTK viewer's feedback
# composer and the report folder it files (docs/reference/viewer-feedback.md).
# The feedback button opens a pill under the nav bar hosting the shared
# src/viewer/composer.js in a second web view; plain Enter is a newline,
# Ctrl+Enter sends, Escape closes, the text survives a close/reopen, and a send
# writes <worktree>/temp/feedback/new/<stem>/report.json (staging + one atomic
# rename) with the source, worktree, branch, commit, pane id, viewport and the
# page selection, then shows "Filed ..." and closes.
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-composer.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the
# debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# `composer` reports the composer once its page is up and no send is out;
# `composer-type` types through the engine's insertText; `composer-key` fires
# a keydown in the composer page (the shim's chords run on keydown).
#
# Output: one PASS/FAIL line per check, then 'VIEWER COMPOSER: ALL PASS' or
# 'VIEWER COMPOSER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER COMPOSER"

log=/tmp/viewer-composer-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "C1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "C2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixture: a repo on a named branch with one commit ----------------------
fx="$HL_RUNTIME/fx"
repo="$fx/repo"
mkdir -p "$repo/docs"
g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.invalid -c user.name=t "$@"; }
env -u GIT_DIR -u GIT_WORK_TREE git init -q -b fbranch "$repo" || echo "git init failed"
printf '# In Repo\n\ntext\n' > "$repo/docs/doc.md"
g add docs/doc.md && g commit -q -m init || echo "git commit failed"
head=$(g rev-parse HEAD)
queue="$repo/temp/feedback/new"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# Select the heading in the PAGE: what the report's source.selection carries.
SEL="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');var r=document.createRange();r.selectNodeContents(h);var s=getSelection();s.removeAllRanges();s.addRange(r);return s.toString()})()"
BOX="JSON.stringify(document.getElementById('c').innerText)"

steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
feedback
composer
click feedback
composer
composer-type first line\nsecond line
sleep 400
composer
composer-key Enter
sleep 300
composer
composer-key Escape
sleep 300
composer
click feedback
composer
composer-probe $BOX
probe $SEL
composer-key ctrl+Enter
composer
sleep 2500
composer
click feedback
composer
composer-key ctrl+Enter
sleep 300
composer
composer-type by the button
sleep 400
click feedback-send
composer
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "C3 the app serves its socket" $?

o=$(cli +split --view="$repo/docs/doc.md" --name=doc 2>&1)
hl_check "C4 +split --view=<repo file> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK In Repo" ]
hl_check "C5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 120 grep -qs '^done' "$out"
hl_check "C6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
co() { nth 'composer ' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(nth feedback 1)
has "$s" "button=true worktree=$repo "
hl_check "C7 the repo file shows the feedback button" $? "$s"

s=$(co 1)
has "$s" "open=false view=false"
hl_check "C8 before any click there is no composer and no second web view (D43)" $? "$s"

s=$(co 2)
has "$s" "open=true view=true ready=true" && has "$s" "status=Ctrl+Enter sends to repo"
hl_check "C9 clicking the button opens the composer; its page loads and says ready; the footer names the worktree" $? "$s"

s=$(co 3)
has "$s" 'text=first line\nsecond line' && has "$s" "lines=2"
hl_check "C10 typed text reaches the pane's buffer through the page's snapshot, with a newline, and the box grows to 2 lines" $? "$s"

s=$(co 4)
has "$s" "open=true" && has "$s" "sends=0"
hl_check "C11 plain Enter does not send" $? "$s"

s=$(co 5)
has "$s" "open=false view=false" && has "$s" 'text=first line\nsecond line'
hl_check "C12 Escape closes the composer and drops its web view; the text stays on the pane" $? "$s"

s=$(co 6)
p=$(nth probe 1)
has "$s" "open=true view=true ready=true" && [ "$p" = 'probe OK "first line\nsecond line"' ]
hl_check "C13 reopening re-seeds a fresh page with the kept text" $? "$s / $p"

[ "$(nth probe 2)" = "probe OK In Repo" ]
hl_check "C14 the page's heading is selected (the report's selection)" $? "$(nth probe 2)"

s=$(co 7)
has "$s" "sends=1" && has "$s" "sending=false" && has "$s" "status=Filed temp/feedback/new/" && has "$s" "text=" && ! has "$s" "text=first"
hl_check "C15 Ctrl+Enter files the report, clears the composer and shows Filed" $? "$s"

s=$(co 8)
has "$s" "open=false view=false"
hl_check "C16 the composer closes on its own after the Filed confirmation" $? "$s"

s=$(co 10)
has "$s" "status=Nothing to send yet" && has "$s" "sends=1"
hl_check "C17 Ctrl+Enter on an empty composer files nothing and says so" $? "$s"

s=$(co 11)
has "$s" "sends=2"
hl_check "C18 the send button files too" $? "$s"

# ---- the reports on disk -----------------------------------------------------
n=$(find "$queue" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$n" = 2 ]
hl_check "C19 exactly two report folders landed in temp/feedback/new" $? "found $n: $(ls "$queue" 2>/dev/null | tr '\n' ' ')"

left=$(find "$repo/temp/feedback/.staging" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
[ "$left" = 0 ]
hl_check "C20 nothing is left in .staging (each folder moved by one rename)" $? "left: $left"

first=$(ls "$queue" 2>/dev/null | sort | head -1)
rj="$queue/$first/report.json"
check_json() {
    python3 - "$rj" "$repo" "$head" <<'PY'
import json, sys, re
p, repo, head = sys.argv[1], sys.argv[2], sys.argv[3]
r = json.load(open(p))
s, w = r["source"], r["worktree"]
bad = []
def want(name, cond):
    if not cond: bad.append(name)
want("body", r.get("body") == "first line\nsecond line")
want("id", r.get("id") == p.split("/")[-2])
want("kind", s.get("kind") == "file")
want("location", s.get("location") == repo + "/docs/doc.md")
want("filePath", s.get("filePath") == repo + "/docs/doc.md")
want("relativePath", s.get("relativePath") == "docs/doc.md")
want("selection", s.get("selection") == "In Repo")
want("paneID", isinstance(s.get("paneID"), str) and len(s["paneID"]) >= 8)
want("viewport", re.fullmatch(r"\d+x\d+", s.get("viewport") or "") is not None)
want("pageTitle", bool(s.get("pageTitle")))
want("worktree.path", w.get("path") == repo)
want("worktree.name", w.get("name") == "repo")
want("branch", w.get("branch") == "fbranch")
want("commit", w.get("commit") == head)
want("app", r.get("app", {}).get("name") == "Ghoztty")
want("quotes", r.get("quotes") == [])
want("images", r.get("images") == [])
print("bad=" + ",".join(bad) if bad else "ok")
PY
}
res=$(check_json 2>&1)
[ "$res" = ok ]
hl_check "C21 report.json carries the body, source (kind/file/relativePath/selection/paneID/viewport), worktree branch+commit and app" $? "$res :: $(head -c 900 "$rj" 2>/dev/null)"

grep -q "viewer feedback: filed $queue/" "$APP_LOG"
hl_check "C22 the app logged each filed folder" $? "$(grep 'viewer feedback' "$APP_LOG" | tail -5 | tr '\n' ' ')"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "C23 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
