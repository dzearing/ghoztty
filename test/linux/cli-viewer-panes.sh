#!/usr/bin/env bash
# cli-viewer-panes.sh - L9b (T3411) acceptance: a viewer is a PANE of the GTK
# app's split tree. `+split --view` and `+new-window --view` open one (a
# relative path against the caller's cwd, `about:blank` as a blank browser
# pane, a `git-status:` spec never path-resolved), `+list` reports it as
# `type: viewer` with its `url` (and the text form prints `view:`), the
# terminal verbs refuse it with the shared sentence, a `--name` is idempotent
# against the same view and conflicts with another, and `+close` closes it
# with no confirmation. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-viewer-panes.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. A pane's page is read back through the
# debug build's GHOZTTY_TEST_VIEWER_DUMP seam (src/apprt/gtk/Viewer.zig).
#
# Output: one PASS/FAIL line per check, then 'CLI VIEWER PANES: ALL PASS' or
# 'CLI VIEWER PANES: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI VIEWER PANES"

log=/tmp/cli-viewer-panes-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

fx="$HL_RUNTIME/fx"
mkdir -p "$fx/sub"
printf '# Pane Heading\n\ntext\n' > "$fx/doc.md"
printf '# Other Doc\n' > "$fx/other.md"
printf '# Raw Socket Doc\n' > "$fx/sub/raw.md"

# Every CLI call runs FROM the fixture dir, so a relative --view resolves there.
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"); }

# raw <action> <arg>...: one request straight to the socket, as a client that
# is not our CLI would send it (no CLI-side path resolution).
cat > "$HL_RUNTIME/raw.py" <<'PY'
import json, socket, struct, sys
path, action, args = sys.argv[1], sys.argv[2], sys.argv[3:]
body = json.dumps({"action": action, "arguments": args}).encode()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(path)
s.sendall(struct.pack(">I", len(body)) + body)
def need(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise SystemExit("short read")
        b += c
    return b
n = struct.unpack(">I", need(4))[0]
print(need(n).decode())
PY
raw() { python3 "$HL_RUNTIME/raw.py" "$sock" "$@" 2>&1; }

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="(function(){var h=document.querySelector('#content h1');return h?h.textContent:(document.body?document.body.innerText.slice(0,80):'NOBODY')})()"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE
hl_wait_for 30 test -S "$sock"
hl_check "P3 the app serves its socket" $?

# leaves [window]: one line per leaf, 'window|name|type|url|title'.
leaves() {
    cli +list --json 2>/dev/null | python3 -c '
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
            print("%s|%s|%s|%s|%s" % (w.get("target") or "", l.get("name") or "", l.get("type"), l.get("url") or "", l.get("title") or ""))
' 2>/dev/null
}
leaf() { leaves | awk -F'|' -v n="$1" '$2 == n'; }
count() { leaves | wc -l; }
dump_list() { leaves | tr '\n' ' '; }

have_leaf() { [ "$(count)" -ge 1 ]; }
hl_wait_for 20 have_leaf
base=$(count)

# ---- +split --view with a relative path ------------------------------------
rm -f "$dump"
out=$(cli +split --view=doc.md --name=doc 2>&1); rc=$?
hl_check "P4 +split --view=doc.md (relative) is created" $rc "$out"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Pane Heading" ]
hl_check "P5 the viewer pane renders the markdown file" $? "dump: $(cat "$dump" 2>/dev/null)"

l=$(leaf doc)
[ "$(echo "$l" | cut -d'|' -f3)" = viewer ] && [ "$(echo "$l" | cut -d'|' -f4)" = "$fx/doc.md" ]
hl_check "P6 +list --json: the leaf is type viewer, url resolved against the caller's cwd" $? "leaf: $l"
[ "$(echo "$l" | cut -d'|' -f5)" = doc.md ]
hl_check "P7 the viewer pane is titled by its file name" $? "leaf: $l"
[ "$(count)" = $((base + 1)) ]
hl_check "P8 the split added exactly one leaf" $? "$(dump_list)"
cli +list 2>/dev/null | grep -q "view: doc.md"
hl_check "P9 +list (text) prints the viewer leaf as 'view:'" $? "$(cli +list 2>&1 | grep -i view | head -2 | tr '\n' ' ')"

# ---- the terminal verbs refuse it ------------------------------------------
out=$(cli +read --name=doc 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "doc is a viewer pane, not a terminal"
hl_check "P10 +read on a viewer pane fails with the viewer sentence" $? "rc=$rc out=$out"
out=$(cli +send-keys --target=doc hello 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "doc is a viewer pane, not a terminal"
hl_check "P11 +send-keys on a viewer pane fails with the viewer sentence" $? "rc=$rc out=$out"

# ---- --name idempotence: same view reuses, another view conflicts ----------
out=$(cli +split --view=doc.md --name=doc 2>&1); rc=$?
[ $rc = 0 ] && [ "$(count)" = $((base + 1)) ]
hl_check "P12 the same +split --view --name again reuses the pane" $? "rc=$rc out=$out list: $(dump_list)"
out=$(cli +split --view=other.md --name=doc 2>&1); rc=$?
[ $rc != 0 ] && [ "$(count)" = $((base + 1)) ]
hl_check "P13 a different --view under the same --name is refused" $? "rc=$rc out=$out"

# ---- locations that are never path-resolved --------------------------------
out=$(cli +split --view=git-status: --name=gd 2>&1); rc=$?
l=$(leaf gd)
[ $rc = 0 ] && [ "$(echo "$l" | cut -d'|' -f3)" = viewer ] && [ "$(echo "$l" | cut -d'|' -f4)" = "git-status:" ]
hl_check "P14 +split --view=git-status: opens a viewer whose url is the spec, not a path" $? "rc=$rc out=$out leaf: $l"

out=$(cli +new-window --target=vw --name=blank --view=about:blank 2>&1); rc=$?
hl_check "P15 +new-window --view=about:blank is created" $rc "$out"
have_vw() { leaves | grep -q '^vw|'; }
hl_wait_for 20 have_vw
l=$(leaves | grep '^vw|')
[ "$(echo "$l" | wc -l)" = 1 ] && [ "$(echo "$l" | cut -d'|' -f2-4)" = "blank|viewer|about:blank" ]
hl_check "P16 the new window holds one blank browser viewer pane" $? "vw: $l"

# ---- the server's own resolution, for a client that is not our CLI ---------
out=$(raw split "--view=raw.md" "--working-directory=$fx/sub" "--name=raw");
l=$(leaf raw)
[ "$(echo "$l" | cut -d'|' -f4)" = "$fx/sub/raw.md" ]
hl_check "P17 a raw +split resolves a relative --view against --working-directory" $? "reply: $out leaf: $l"

# ---- +close never prompts ---------------------------------------------------
before=$(count)
out=$(cli +close --target=doc 2>&1); rc=$?
gone_doc() { [ -z "$(leaf doc)" ]; }
hl_wait_for 10 gone_doc
[ $rc = 0 ] && [ -z "$(leaf doc)" ] && [ "$(count)" = $((before - 1)) ]
hl_check "P18 +close closes a viewer pane at once (no confirmation)" $? "rc=$rc out=$out list: $(dump_list)"
out=$(cli +close --target=vw 2>&1); rc=$?
no_vw() { ! have_vw; }
hl_wait_for 10 no_vw
hl_check "P19 +close closes a window holding only a viewer" $? "rc=$rc out=$out list: $(dump_list)"

kill -0 "$APP" 2>/dev/null
hl_check "P20 the app is still running" $?
grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ]
hl_check "P21 the app log carries no panic" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- app log (viewer/ipc lines) ----"
    grep -iE 'viewer|ipc|webkit|critical|error|warn' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi
hl_finish "$L"
