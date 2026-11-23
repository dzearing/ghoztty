#!/usr/bin/env bash
# viewer-diff.sh - L9h (T3417) acceptance: GTK git diff viewer panes.
#
# docs/reference/viewer-image-and-diff.md "Git diff panes", on Linux:
# - `--view=git-status:` lists staged, unstaged and untracked changes as three
#   sections, against the repository of --working-directory (the caller's
#   cwd), and +list reports the spec as the pane's url;
# - the changed-files panel: a header counting the files, a filter that
#   narrows on every keystroke to a flat hit list ("1 of 5 files"), Return
#   opens the top hit, Escape puts the list back and hands the caret to the
#   diff; folders fold; chains of single-child folders collapse into one row;
# - a Latin-1 file's patch still renders (stray bytes become U+FFFD);
# - the bar's layout toggle switches unified <-> side by side and persists
#   the preference;
# - `git-diff:a...b`, `git-diff:<sha>` (that one commit) and `git-diff:`
#   (this branch against main) each list the right files; a binary file gets
#   a stub, a rename keeps its status;
# - next change rolls into the adjacent file, entered at its first change;
#   previous change at the top of a file enters the one before at its LAST;
# - a directory in no repository and a revspec that names nothing get
#   explanatory cards, never a blank pane;
# - a git-status: pane notices an edit made elsewhere within a couple of
#   polls, and an idle one costs only the fingerprint;
# - nothing panics.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-diff.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh); the pane is driven
# and read back through the debug build's GHOZTTY_TEST_VIEWER_STEPS seam
# (src/apprt/gtk/Viewer.zig; its `diff` / `rows` steps read ViewerDiff's
# state), and the driving script edits the fixture repo at `mark` points.
#
# Output: one PASS/FAIL line per check, then 'VIEWER DIFF: ALL PASS' or
# 'VIEWER DIFF: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER DIFF"

log=/tmp/viewer-diff-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "D1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "D2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- the fixture repository --------------------------------------------------
# main: README, a nested source file, a guide, a file to delete. feature (the
# checked-out branch) changes the engine, adds a doc and a binary, deletes
# old.txt and renames the guide. On top of that the working tree has a staged
# README edit, an unstaged edit to README AND to view.zig, and two untracked
# files - one of them Latin-1.
repo="$HL_RUNTIME/repo"
norepo="$HL_RUNTIME/norepo"
mkdir -p "$repo" "$norepo"
g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.name=t -c user.email=t@example.invalid "$@" > /dev/null 2>&1; }
g init -b main
mkdir -p "$repo/src/app/core" "$repo/src/app/ui" "$repo/docs" "$repo/assets"
printf '# Fixture\n\nintro\n' > "$repo/README.md"
seq 1 12 | sed 's/^/const line_/; s/$/ = 0;/' > "$repo/src/app/core/engine.zig"
printf 'pub fn view() void {}\n' > "$repo/src/app/ui/view.zig"
printf 'guide\nline two\n' > "$repo/docs/guide.md"
printf 'old\n' > "$repo/old.txt"
g add -A
g commit -m base
g checkout -b feature
sed -i 's/const line_3 = 0;/const line_3 = 33;/' "$repo/src/app/core/engine.zig"
printf 'const added_a = 1;\nconst added_b = 2;\n' >> "$repo/src/app/core/engine.zig"
printf 'new doc\n' > "$repo/docs/new.md"
printf '\x00\x01\x02binary\x00' > "$repo/assets/logo.bin"
g rm -q old.txt
g mv docs/guide.md docs/manual.md
g add -A
g commit -m feature
sha=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" rev-parse --short HEAD)
printf '# Fixture\n\nintro, staged\n' > "$repo/README.md"
g add README.md
printf '# Fixture\n\nintro, staged\nand unstaged\n' > "$repo/README.md"
printf 'pub fn view() void {}\n// unstaged\n' > "$repo/src/app/ui/view.zig"
printf 'note\n' > "$repo/notes.txt"
printf 'caf\xe9 au lait\n' > "$repo/latin1.txt"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli_in() { local d=$1; shift; (cd "$d" && env -u GIT_DIR -u GIT_WORK_TREE -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

PAGE="(function(){var h=document.querySelector('.d-file-header');var b=document.querySelector('.d-body');var n=document.querySelector('.d-notice');return 'file='+(h?h.innerText.replace(/\\s+/g,' '):'-')+' body='+(b?b.className.replace('d-body ',''):'-')+' add='+document.querySelectorAll('.d-line.d-add').length+' del='+document.querySelectorAll('.d-line.d-del').length+' fffd='+(document.body.innerText.indexOf('\\ufffd')>=0)+' stub='+(document.querySelector('.d-stub')?document.querySelector('.d-stub').innerText.replace(/\\s+/g,' '):'-')+' notice='+(n?n.innerText.replace(/\\s+/g,' '):'-')})()"

# ---- the steps the first pane runs once it has rendered ----------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
sleep 1500
diff
rows
probe $PAGE
filter lat
diff
rows
filter-submit
wait
sleep 300
diff
probe $PAGE
filter-focus
key Escape
diff
state
click diff-layout
sleep 300
diff
probe $PAGE
click diff-layout
sleep 300
diff
probe $PAGE
mark live
sleep 6000
diff
sleep 4500
diff
key <Control>l
type git-diff:main...HEAD
activate
wait
sleep 1500
diff
rows
row committed:src/app/core
diff
rows
row committed:src/app/core
row assets/logo.bin
wait
sleep 300
diff
probe $PAGE
click diff-next
wait
sleep 400
diff
probe $PAGE
click diff-prev
wait
sleep 400
diff
key <Control>l
type git-diff:$sha
activate
wait
sleep 1500
diff
rows
key <Control>l
type git-diff:
activate
wait
sleep 1500
diff
key <Control>l
type git-diff:nosuchref
activate
wait
sleep 1500
diff
probe $PAGE
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
# The layout preference lands in the harness, never in the user's ~/.local.
export XDG_STATE_HOME="$HL_RUNTIME/state"
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="(function(){var s=document.querySelector('.d-summary');return s?'SUMMARY '+s.innerText.replace(/\\s+/g,' '):'NOSUMMARY'})()"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "D3 the app serves its socket" $?

o=$(cli_in "$repo/src" +split --view=git-status: --name=diff 2>&1)
hl_check "D4 +split --view=git-status: from inside the repo opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
case "$(cat "$dump" 2>/dev/null)" in "OK SUMMARY "*Working\ tree*) true ;; *) false ;; esac
hl_check "D5 the page renders the diff's summary (Working tree)" $? "dump: $(cat "$dump" 2>/dev/null)"

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
grep -q "viewer diff spec=git-status: repo=$repo files=5 " "$APP_LOG"
hl_check "D6 the listing runs against the repository root of the caller's cwd: 5 files" $? "$(grep 'viewer diff spec=' "$APP_LOG" | head -2 | tr '\n' ' ')"

leaf() {
    cli_in "$repo" +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("name") == "diff":
                print("%s|%s" % (l.get("type"), l.get("url") or ""))
' 2>/dev/null
}
lf=$(leaf)
[ "$lf" = "viewer|git-status:" ]
hl_check "D7 +list reports the pane as a viewer whose url is the spec" $? "leaf: $lf"

# A second pane from a directory in no repository: the card says so.
o=$(cli_in "$norepo" +split --view=git-status: --name=norepo 2>&1)
hl_wait_for 20 grep -q "viewer diff spec=git-status: repo=<none> files=0 .*status=Not a git repository" "$APP_LOG"
hl_check "D8 a directory in no repository gets the 'Not a git repository' card" $? "$o $(grep 'repo=<none>' "$APP_LOG" | head -1)"

# ---- the driving script's half of the sync points ----------------------------
hl_wait_for 90 grep -q '^mark live$' "$out"
listings_before=$(grep -c 'viewer diff spec=git-status: repo=' "$APP_LOG")
printf 'pub fn view() void {}\n// unstaged\n// and more\n' > "$repo/src/app/ui/view.zig"
hl_wait_for 180 grep -q '^done' "$out"
hl_check "D9 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
df() { nth "diff " "$1"; }
rw() { nth "rows " "$1" | sed 's/^rows //'; }
pr() { nth "probe " "$1"; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

d1=$(df 1); r1=$(rw 1)
has "$r1" "section:Staged" && has "$r1" "section:Untracked" && [ "$(echo "$r1" | tr '|' '\n' | grep -c '^section:')" = 3 ]
hl_check "D10 staged, unstaged and untracked are three sections" $? "$r1"
has "$d1" "panel=true" && has "$d1" "header=5 files changed" && [ "$(field "$d1" files)" = 5 ]
hl_check "D11 the panel shows, headed by the file count" $? "$d1"
[ "$(field "$d1" file)" != "-" ] && [ "$(field "$d1" selected)" = "$(field "$d1" file)" ]
hl_check "D12 a file opens straight away and its row is selected" $? "$d1"

d2=$(df 2); r2=$(rw 2)
has "$d2" "header=1 of 5 files" && has "$r2" "file:latin1.txt"
hl_check "D13 the filter narrows on the keystroke to a flat hit list" $? "$d2 / $r2"
d3=$(df 3); p2=$(pr 2)
[ "$(field "$d3" file)" = "latin1.txt" ] && has "$p2" "fffd=true" && has "$p2" "add=1"
hl_check "D14 Return opens the top hit; a Latin-1 patch renders with U+FFFD" $? "$d3 / $p2"
grep -q '^key Escape handled=true' "$out" && has "$(df 4)" "header=5 files changed" && has "$(nth state 1)" "focus=content"
hl_check "D15 Escape in the filter puts the list back and hands the caret to the diff" $? "$(grep '^key Escape' "$out") $(df 4) $(nth state 1)"

has "$(df 5)" "style=split" && has "$(pr 3)" "body=d-split" && has "$(df 6)" "style=unified" && has "$(pr 4)" "body=d-unified"
hl_check "D16 the layout toggle switches side by side and back" $? "$(df 5) $(pr 3) / $(df 6) $(pr 4)"
[ "$(cat "$XDG_STATE_HOME/ghoztty/viewer_diff_style-debug" 2>/dev/null)" = "unified" ]
hl_check "D17 the layout is persisted as a preference (XDG state dir)" $? "$(ls -R "$XDG_STATE_HOME" 2>&1 | tr '\n' ' ')"

listings_after=$(grep -c 'viewer diff spec=git-status: repo=' "$APP_LOG")
[ "$listings_after" -gt "$listings_before" ] && grep -q "files=5 +[0-9]* -[0-9]* style=unified status=ok" "$APP_LOG"
hl_check "D18 an edit made elsewhere reaches a git-status: pane within a few polls" $? "before=$listings_before after=$listings_after"
u7=$(field "$(df 7)" unchanged); u8=$(field "$(df 8)" unchanged)
[ -n "$u8" ] && [ "$u8" -gt "${u7:-0}" ]
hl_check "D19 an idle git-status: pane polls by fingerprint only (unchanged polls grow)" $? "$(df 7) / $(df 8)"

d9=$(df 9); r3=$(rw 3)
[ "$(field "$d9" files)" = 5 ] && has "$r3" "folder:src/app/core" && has "$r3" "file:manual.md" && has "$r3" "file:logo.bin"
hl_check "D20 git-diff:main...HEAD lists the branch's 5 files; single-child folders collapse into one row" $? "$d9 / $r3"
r4=$(rw 4)
has "$r4" "folder:src/app/core*" && ! has "$r4" "file:engine.zig"
hl_check "D21 clicking a folder folds it" $? "$r4"
d11=$(df 11); p5=$(pr 5)
[ "$(field "$d11" file)" = "assets/logo.bin" ] && has "$p5" "stub=Binary file"
hl_check "D22 a binary file gets a stub, not a patch" $? "$d11 / $p5"
d12=$(df 12); p6=$(pr 6)
[ "$(field "$d12" file)" != "assets/logo.bin" ] && grep -q 'viewer diff overflow forward=true' "$APP_LOG" && grep -q 'scroll=first' "$APP_LOG"
hl_check "D23 next change past the last one rolls into the next file, at its first change" $? "$d12 / $p6"
d13=$(df 13)
[ "$(field "$d13" file)" = "assets/logo.bin" ] && grep -q 'viewer diff overflow forward=false' "$APP_LOG" && grep -q 'scroll=last' "$APP_LOG"
hl_check "D24 previous change at the top rolls back into the previous file, at its last change" $? "$d13"

d14=$(df 14); r5=$(rw 5)
[ "$(field "$d14" files)" = 5 ] && grep -q "viewer diff spec=git-diff:$sha repo=$repo files=5 " "$APP_LOG"
hl_check "D25 git-diff:<sha> is that one commit's own changes" $? "$d14 / $r5"
grep -q "viewer diff spec=git-diff: repo=$repo files=5 .*status=ok" "$APP_LOG"
hl_check "D26 a bare git-diff: compares this branch against main" $? "$(grep 'spec=git-diff: ' "$APP_LOG" | head -1)"
p7=$(pr 7)
grep -q 'viewer diff spec=git-diff:nosuchref .*files=0 .*status=git could not produce this diff' "$APP_LOG" && has "$p7" "git could not produce this diff"
hl_check "D27 a revspec that names nothing gets an explanatory card" $? "$p7"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "D28 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -80
fi
hl_finish "$L"
