#!/usr/bin/env bash
# viewer-feedback.sh - L9j (T3419) acceptance: the GTK viewer's feedback
# button and the worktree provenance behind it (docs/reference/viewer-feedback.md,
# strategy D). A pane showing a file inside a git working tree gets an
# icon-only button at the end of its nav bar, tooltip "Send feedback to
# <root>"; a file outside every repo gets none; an http://127.0.0.1:<port> page
# is attributed to the LISTENING process's working directory (Linux's lsof:
# /proc/net/tcp -> socket inode -> /proc/<pid>/fd -> /proc/<pid>/cwd); any
# other website falls back to the pane's --working-directory. The answer is
# re-decided on every navigation and cached, so a Back walk never re-runs git.
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-feedback.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the
# debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# `feedback` reports the button once any resolution in flight has landed.
#
# Output: one PASS/FAIL line per check, then 'VIEWER FEEDBACK: ALL PASS' or
# 'VIEWER FEEDBACK: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER FEEDBACK"

log=/tmp/viewer-feedback-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
# Three repos and one plain directory, none inside another: the runtime dir
# lives under /tmp, which no repo contains.
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/repo/docs" "$fx/outside" "$fx/srvrepo/web" "$fx/origrepo" "$fx/plainsite"
for r in repo srvrepo origrepo; do
    env -u GIT_DIR -u GIT_WORK_TREE git init -q "$fx/$r" || echo "git init $r failed"
done
printf '# In Repo\n\ntext\n' > "$fx/repo/docs/doc.md"
printf '# Outside\n' > "$fx/outside/plain.md"
printf '<!DOCTYPE html><html><body><h1>Dev Server</h1></body></html>\n' > "$fx/srvrepo/web/index.html"
printf '<!DOCTYPE html><html><body><h1>Plain Site</h1></body></html>\n' > "$fx/plainsite/index.html"

# A dev server whose working directory is INSIDE srvrepo (its web/ folder),
# so the button must name the repo root, not the server's own folder.
port=$((20000 + $$ % 20000))
(cd "$fx/srvrepo/web" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HL_PIDS="$HL_PIDS $!"
# A site on a loopback address that is NOT one of the dev-server names
# (127.0.0.2): leg 2 does not apply, so it falls back to the pane's origin.
port2=$((port + 1))
(cd "$fx/plainsite" && exec python3 -m http.server "$port2" --bind 127.0.0.2) > "$HL_RUNTIME/http2.log" 2>&1 &
HL_PIDS="$HL_PIDS $!"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.2/$port2" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"

# ---- the steps the first pane runs once it has rendered ---------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
feedback
key <Control>l
type $fx/outside/plain.md
activate
wait
probe $H
feedback
key <Control>l
type 127.0.0.1:$port/
activate
wait
probe $H
feedback
click back
wait
feedback
click back
wait
feedback
click feedback
feedback
mark split
sleep 4000
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
hl_check "F3 the app serves its socket" $?

o=$(cli +split --view="$fx/repo/docs/doc.md" --name=doc 2>&1)
hl_check "F4 +split --view=<repo file> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK In Repo" ]
hl_check "F5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 90 grep -qs '^mark split' "$out"
# The origin leg, in a second pane: a website that is not a dev server name,
# opened from origrepo.
o=$(cli +split --view="http://127.0.0.2:$port2/" --working-directory="$fx/origrepo" --name=site 2>&1)
hl_check "F6 +split --view=<website> --working-directory=<repo> opens a second pane" $? "$o"
hl_wait_for 60 grep -qs '^done' "$out"
hl_check "F7 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"
hl_wait_for 20 grep -q "viewer feedback: worktree=$fx/origrepo " "$APP_LOG"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
fb() { nth feedback "$1"; }
pr() { nth probe "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
field() { printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

s=$(fb 1)
has "$s" "button=true worktree=$fx/repo tip=Send feedback to $fx/repo pending=false"
hl_check "F8 a file inside a git repo shows the button, its tooltip naming the repo ROOT (not the file's folder)" $? "$s"

s=$(fb 2)
[ "$(pr 1)" = "probe OK Outside" ] && has "$s" "button=false worktree=- tip=- pending=false"
hl_check "F9 navigating to a file outside every repo hides it (re-decided per navigation)" $? "$(pr 1) / $s"

s=$(fb 3)
[ "$(pr 2)" = "probe OK Dev Server" ] && has "$s" "button=true worktree=$fx/srvrepo tip=Send feedback to $fx/srvrepo "
hl_check "F10 a 127.0.0.1:<port> page is attributed to the listening server's cwd, resolved to its repo root" $? "$(pr 2) / $s"
grep -q "viewer feedback: port $port is served from $fx/srvrepo/web" "$APP_LOG"
hl_check "F11 the listener was found through /proc (port -> socket inode -> pid -> cwd)" $? "$(grep -m3 'viewer feedback' "$APP_LOG" | tr '\n' ' ')"

s4=$(fb 4); s5=$(fb 5)
has "$s4" "button=false worktree=-" && has "$s5" "button=true worktree=$fx/repo "
hl_check "F12 Back walks the button with the pane: outside -> none, repo file -> the repo again" $? "$s4 / $s5"
r3=$(field "$(fb 3)" resolves); r5=$(field "$s5" resolves)
[ -n "$r3" ] && [ "$r3" = "$r5" ]
hl_check "F13 the Back walk is served from the 15 s cache (no new git resolution)" $? "resolves after web=$r3, after two Backs=$r5"

s=$(fb 6)
has "$s" "clicks=1" && grep -q "viewer feedback: clicked worktree=$fx/repo; the composer is not built on Linux yet (T3544)" "$APP_LOG"
hl_check "F14 clicking the button is received (the composer is T3544's)" $? "$s"

grep -q "viewer feedback: worktree=$fx/origrepo name=origrepo" "$APP_LOG"
hl_check "F15 a website that is not a dev server falls back to the pane's --working-directory" $? "$(grep 'viewer feedback: worktree' "$APP_LOG" | tr '\n' ' ')"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "F16 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
