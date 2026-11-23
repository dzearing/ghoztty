#!/usr/bin/env bash
# viewer-composer-draft.sh - L9j-6 (T3553) acceptance: the GTK feedback
# composer's draft folder (Mac's feedbackDraftStem + stagingLink, win32 T645).
# Opening the composer mints a draft stem; the footer links
# <worktree>/temp/feedback/.staging/<stem> (nothing is written until the link
# is clicked); the click stages report.json there and opens the folder (a test
# run refuses the hand-off to the desktop, and says so); a file dropped into
# that folder rides along into temp/feedback/new/<the same stem>/ when the
# report is sent; the filed stem is retired, so the next composer gets a new
# one; and staging sweeps a draft folder abandoned for over a day.
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-composer-draft.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the
# debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# `click feedback-folder` clicks the footer link; `composer` reports stem=,
# link= (the link's label while it shows), reveals= and staged=.
#
# Output: one PASS/FAIL line per check, then 'VIEWER COMPOSER DRAFT: ALL PASS'
# or 'VIEWER COMPOSER DRAFT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER COMPOSER DRAFT"

log=/tmp/viewer-composer-draft-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "D1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "D2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixture: a repo, plus two leftover draft folders -----------------------
fx="$HL_RUNTIME/fx"
repo="$fx/repo"
mkdir -p "$repo/docs"
g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.invalid -c user.name=t "$@"; }
env -u GIT_DIR -u GIT_WORK_TREE git init -q -b dbranch "$repo" || echo "git init failed"
printf '# Draft Doc\n\ntext\n' > "$repo/docs/doc.md"
g add docs/doc.md && g commit -q -m init || echo "git commit failed"
queue="$repo/temp/feedback/new"
stg="$repo/temp/feedback/.staging"
# One abandoned two days ago (swept by the next staging write) and one from
# another pane an hour ago (left alone: it may be somebody's live draft).
mkdir -p "$stg/20200101T000000Z-aaaaaa" "$stg/20200101T000000Z-bbbbbb"
echo old > "$stg/20200101T000000Z-aaaaaa/report.json"
echo live > "$stg/20200101T000000Z-bbbbbb/report.json"
touch -d '2 days ago' "$stg/20200101T000000Z-aaaaaa/report.json" "$stg/20200101T000000Z-aaaaaa"
touch -d '1 hour ago' "$stg/20200101T000000Z-bbbbbb/report.json" "$stg/20200101T000000Z-bbbbbb"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"

steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
composer
click feedback
composer
mark opened
sleep 2500
composer-type draft words
sleep 400
click feedback-folder
composer
mark staged
sleep 4000
composer-key ctrl+Enter
composer
sleep 2500
click feedback
composer
composer-key Escape
sleep 300
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
hl_check "D3 the app serves its socket" $?

o=$(cli +split --view="$repo/docs/doc.md" --name=doc 2>&1)
hl_check "D4 +split --view=<repo file> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Draft Doc" ]
hl_check "D5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
co() { nth 'composer ' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
field() { printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

# While the composer is open and nothing has been clicked: no draft folder.
hl_wait_for 90 grep -qs '^mark opened' "$out"
stem=$(field "$(co 2)" stem)
pre_exists=no
[ -n "$stem" ] && [ -e "$stg/$stem" ] && pre_exists=yes

# The draft is staged: drop a "log" into its folder, the way a user would.
hl_wait_for 30 grep -qs '^mark staged' "$out"
dropped=no
if [ -n "$stem" ] && [ -d "$stg/$stem" ]; then
    printf 'crash at 0xdead\n' > "$stg/$stem/crash.log" && dropped=yes
fi

hl_wait_for 60 grep -qs '^done' "$out"
hl_check "D6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

s=$(co 1)
has "$s" "open=false" && has "$s" "stem=- link=-"
hl_check "D7 before the composer opens there is no draft" $? "$s"

s=$(co 2)
case "$stem" in [0-9]*T*Z-*) okstem=0 ;; *) okstem=1 ;; esac
[ $okstem = 0 ] && has "$s" "link=repo/temp/feedback/.staging/$stem " && has "$s" "reveals=0" && [ $pre_exists = no ]
hl_check "D8 opening the composer mints a draft stem and the footer links repo/temp/feedback/.staging/<stem> - with nothing on disk yet" $? "$s / exists-before-click=$pre_exists"

s=$(co 3)
has "$s" "reveals=1" && has "$s" "staged=$stg/$stem " && [ "$dropped" = yes ]
hl_check "D9 clicking the link stages the draft's own folder" $? "$s / dropped=$dropped"

grep -q "viewer feedback: reveal stem=$stem folder=$stg/$stem" "$APP_LOG" \
    && grep -q "a test run refused to hand $stg/$stem to the desktop (app)" "$APP_LOG"
hl_check "D10 the click opens that folder through the file launcher (refused, and logged, under test)" $? "$(grep -E 'reveal stem|refused to hand' "$APP_LOG" | tail -3 | tr '\n' ' ')"

[ ! -e "$stg/20200101T000000Z-aaaaaa" ] && [ -e "$stg/20200101T000000Z-bbbbbb" ]
hl_check "D11 staging swept the draft abandoned two days ago and left the hour-old one" $? "$(ls "$stg" 2>/dev/null | tr '\n' ' ')"

s=$(co 4)
has "$s" "sends=1" && has "$s" "status=Filed temp/feedback/new/$stem " && has "$s" "stem=- link=-"
hl_check "D12 the send files under the DRAFT's stem and retires it; the footer shows Filed instead of the link" $? "$s"

[ -f "$queue/$stem/report.json" ] && [ "$(cat "$queue/$stem/crash.log" 2>/dev/null)" = "crash at 0xdead" ] && [ ! -e "$stg/$stem" ]
hl_check "D13 the dropped file rode along into temp/feedback/new/<stem>/ and the draft folder moved (one rename)" $? "$(ls -la "$queue/$stem" 2>/dev/null | tr '\n' ' ')"

body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$queue/$stem/report.json" 2>&1)
[ "$body" = "draft words" ]
hl_check "D14 the published report.json is the sent one (body), not the staged draft's" $? "body=$body"

s=$(co 5)
stem2=$(field "$s" stem)
[ -n "$stem2" ] && [ "$stem2" != "-" ] && [ "$stem2" != "$stem" ] && has "$s" "link=repo/temp/feedback/.staging/$stem2 " && has "$s" "status= text="
hl_check "D15 the next composer opens a NEW draft, and its footer is the link again" $? "$s"

s=$(co 6)
has "$s" "open=false" && has "$s" "stem=$stem2 " && [ ! -e "$stg/$stem2" ]
hl_check "D16 closing an untouched composer keeps its stem and leaves nothing on disk" $? "$s"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "D17 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
