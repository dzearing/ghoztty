#!/usr/bin/env bash
# viewer-subframe.sh - T3554 acceptance: an iframe on a GTK viewer page may
# post the link menu and NOTHING else on the page bridge (win32's
# ViewerPane.onFrameMessage rule). WebKitGTK's script message carries no
# frame, so the native handlers live in a private script world; a page-world
# shim in every frame hands each post to its own frame's private relay, which
# forwards it as the top frame's or a subframe's (src/apprt/gtk/viewer_frames.zig).
#
# The fixture is a rendered .html page in a git repo (so the feedback composer
# has a worktree to file into) holding a CROSS-ORIGIN iframe from a loopback
# server - the shape of an ad on a website. On the parent's "go", the frame
# posts a quote, headings, an active heading, a find count, a file link with
# Ctrl+Shift, a quote forged by firing the relay's own DOM event, and
# right-clicks a link of its own. Then the top frame posts a quote and a file
# link itself: the positive controls that prove the same messages ARE acted on
# from the top.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-subframe.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the debug
# build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig).
#
# Output: one PASS/FAIL line per check, then 'VIEWER SUBFRAME: ALL PASS' or
# 'VIEWER SUBFRAME: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER SUBFRAME"

log=/tmp/viewer-subframe-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixture -----------------------------------------------------------------
fx="$HL_RUNTIME/fx"
repo="$fx/repo"
site="$fx/site"
mkdir -p "$repo" "$site"
port=$((20000 + $$ % 20000))

cat > "$repo/page.html" <<EOF
<!DOCTYPE html><html><head><title>Top</title></head><body><h1>Top Page</h1>
<p>Top paragraph.</p>
<iframe id="fr" src="http://127.0.0.1:$port/frame.html" style="width:300px;height:80px"></iframe>
<script>addEventListener("message",function(e){if(typeof e.data==="string"&&e.data.indexOf("frame|")===0)window.__frame=e.data.slice(6)})</script>
</body></html>
EOF

cat > "$site/frame.html" <<'EOF'
<!DOCTYPE html><html><body><a id="fl" href="https://example.test/framed">framed</a><script>
addEventListener("message", function (e) {
  if (e.data !== "go") return;
  var h = window.webkit && window.webkit.messageHandlers;
  var r = [];
  r.push("toc=" + typeof (h && h.viewerTOC));
  r.push("fl=" + typeof (h && h.ghozttyFileLink));
  r.push("top=" + typeof (h && h.ghozttyTop));
  r.push("sub=" + typeof (h && h.ghozttySubframe));
  var xo; try { void parent.document.body; xo = false; } catch (x) { xo = true; }
  r.push("xo=" + xo);
  try {
    h.viewerTOC.postMessage({ type: "quote", text: "framed passage" });
    h.viewerTOC.postMessage({ type: "headings", items: [{ id: "f", text: "Framed", level: 1 }] });
    h.viewerTOC.postMessage({ type: "active", id: "f" });
    h.viewerTOC.postMessage({ type: "find", query: "framed", total: 3, index: 1 });
    h.ghozttyFileLink.postMessage(JSON.stringify({ href: "file:///etc/hostname", ctrl: true, shift: true }));
    document.dispatchEvent(new CustomEvent("__ghozttyBridge",
      { detail: "viewerTOC\n" + JSON.stringify({ type: "quote", text: "forged passage" }) }));
    r.push("posted=ok");
  } catch (x) { r.push("posted=" + x); }
  document.getElementById("fl").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
  e.source.postMessage("frame|" + r.join(" "), "*");
});
</script></body></html>
EOF

g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.invalid -c user.name=t "$@"; }
env -u GIT_DIR -u GIT_WORK_TREE git init -q -b fbranch "$repo" || echo "git init failed"
g add page.html && g commit -q -m init || echo "git commit failed"

(cd "$site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# Wait (inside the page) until the frame has loaded, then tell it to go.
GO="(function(){var f=document.getElementById('fr');if(!f||!f.contentWindow)return 'noframe';f.contentWindow.postMessage('go','*');return 'go sent'})()"
FRAME="(function(){return 'frame '+(window.__frame||'pending')})()"
TOPNS="(function(){var h=window.webkit&&window.webkit.messageHandlers;return 'topns toc='+typeof(h&&h.viewerTOC)+' top='+typeof(h&&h.ghozttyTop)+' sub='+typeof(h&&h.ghozttySubframe)})()"
TOPQUOTE="(function(){window.webkit.messageHandlers.viewerTOC.postMessage({type:'quote',text:'top passage'});return 'top quote posted'})()"
TOPFILE="(function(){window.webkit.messageHandlers.ghozttyFileLink.postMessage(JSON.stringify({href:'file:///etc/hostname',ctrl:false,shift:false}));return 'top file posted'})()"

steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
sleep 1500
probe $GO
sleep 1500
probe $FRAME
probe $TOPNS
composer
toc
probe $TOPQUOTE
sleep 500
composer
probe $TOPFILE
sleep 500
EOF

dump="$HL_RUNTIME/viewer-dump"
links="$HL_RUNTIME/links.log"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
export GHOZTTY_TEST_VIEWER_LINKS="$links"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT GHOZTTY_TEST_VIEWER_LINKS
hl_wait_for 30 test -S "$sock"
hl_check "F3 the app serves its socket" $?

o=$(cli +split --view="$repo/page.html" --name=page 2>&1)
hl_check "F4 +split --view=<repo page> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Top Page" ]
hl_check "F5 the pane renders its page" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 90 grep -qs '^done' "$out"
hl_check "F6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
co() { nth 'composer ' "$1"; }
pr() { nth 'probe ' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(pr 2)
has "$s" "xo=true" && has "$s" "posted=ok"
hl_check "F7 the iframe is cross-origin to the page, and its posts all went out" $? "$s"

has "$s" "toc=object" && has "$s" "fl=object" && has "$s" "top=undefined" && has "$s" "sub=undefined"
hl_check "F8 the iframe sees the shared scripts' handler names and NOT the native ones (private world)" $? "$s"

s=$(pr 3)
has "$s" "topns toc=object top=undefined sub=undefined"
hl_check "F9 the top page's own scripts see the same: viewerTOC, never the native handlers" $? "$s"

s=$(co 1)
has "$s" "open=false" && has "$s" "quotes=0" && has "$s" "quoted=0"
hl_check "F10 the iframe's quote (and its forged one) left the composer closed with nothing quoted" $? "$s"

s=$(nth 'toc ' 1)
has "$s" "rows=0 " && has "$s" "active=-"
hl_check "F11 the iframe's headings and active heading did not reach the contents" $? "$s"

c=$(grep -c "viewer: dropped a subframe's quote post" "$APP_LOG")
[ "$c" = 2 ] &&
    grep -q "viewer: dropped a subframe's headings post" "$APP_LOG" &&
    grep -q "viewer: dropped a subframe's active post" "$APP_LOG" &&
    grep -q "viewer: dropped a subframe's find post" "$APP_LOG" &&
    grep -q "viewer: dropped a subframe's file_link post" "$APP_LOG"
hl_check "F12 the app logged each subframe post it dropped (quote x2 incl. the forged event, headings, active, find, file link)" $? "quotes=$c $(grep "dropped a subframe" "$APP_LOG" | tr '\n' ' ')"

grep -q '^menu .*https://example.test/framed' "$links" 2>/dev/null
hl_check "F13 the iframe's link still gets the link menu (the one message a subframe may post)" $? "$(cat "$links" 2>/dev/null | tr '\n' ' ')"

s=$(co 2)
has "$s" "open=true" && has "$s" "quotes=1 quoted=1"
hl_check "F14 control: the SAME quote posted by the top page opens the composer with it" $? "$s"

c=$(grep -c "viewer: file link file:///etc/hostname" "$APP_LOG")
[ "$c" = 1 ] && grep -q "viewer: file link file:///etc/hostname .* ctrl=false shift=false" "$APP_LOG"
hl_check "F15 control: only the top page's file link was routed (the iframe's Ctrl+Shift one never was)" $? "count=$c $(grep 'viewer: file link' "$APP_LOG" | tr '\n' ' ')"

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
