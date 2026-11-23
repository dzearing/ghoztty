#!/usr/bin/env bash
# viewer-quote.sh - L9j-3 (T3545) acceptance: quoting a selection from a GTK
# viewer page into the feedback composer (docs/reference/viewer-feedback.md,
# "Quoting"). The shared src/viewer/selection.js toolbar is injected into
# every page; selecting text shows Quote/Copy. Quote opens the composer and
# drops the passage in as its own block (a `.q` node with its id), the report
# carries it as a markdown blockquote in `body` plus its referential context in
# `quotes` (headingId/headingText/blockSelector/blockText/offsets and the
# file's 1-based sourceLine, resolved at send time). Deleting the block drops
# its metadata. Copy puts the selection on the GDK clipboard.
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-quote.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the debug
# build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig). There is
# no pointer on a seatless Weston, so the page's selection is made with a
# Range and the toolbar's buttons get the mousedown they act on; everything
# from the bridge message onward is the real path. Copy is read from the
# GHOZTTY_TEST_VIEWER_LINKS sink `copyText` writes beside the clipboard.
#
# Output: one PASS/FAIL line per check, then 'VIEWER QUOTE: ALL PASS' or
# 'VIEWER QUOTE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER QUOTE"

log=/tmp/viewer-quote-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "Q1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "Q2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixture: a repo with a two-section markdown file ------------------------
fx="$HL_RUNTIME/fx"
repo="$fx/repo"
mkdir -p "$repo/docs"
g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.invalid -c user.name=t "$@"; }
env -u GIT_DIR -u GIT_WORK_TREE git init -q -b qbranch "$repo" || echo "git init failed"
# Line 7 holds the fox, line 9 the river: what sourceLine must find.
printf '# In Repo\n\nIntro paragraph here.\n\n## Second Part\n\nThe quick brown fox jumps over the lazy dog.\n\nAnother line about the river bank.\n' > "$repo/docs/doc.md"
g add docs/doc.md && g commit -q -m init || echo "git commit failed"
queue="$repo/temp/feedback/new"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# Select `word` inside the first paragraph that contains it, then the mouseup
# that ends a drag (the toolbar places itself on the next tick).
sel() {
    printf "%s" "(function(){var w='$1';var ps=document.querySelectorAll('#content p');for(var i=0;i<ps.length;i++){var t=ps[i].firstChild;while(t&&t.nodeType!==3)t=t.nextSibling;if(!t)continue;var at=t.data.indexOf(w);if(at<0)continue;var r=document.createRange();r.setStart(t,at);r.setEnd(t,at+w.length);var s=getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));return 'sel '+s.toString()}return 'NOSEL'})()"
}
# The toolbar: shown?, and its buttons' titles (it lives in a shadow root).
BAR="(function(){var h=document.querySelector('[data-ghoztty-ui]');if(!h)return 'nobar';var b=h.shadowRoot.querySelector('.bar');var t=[];h.shadowRoot.querySelectorAll('button').forEach(function(x){t.push(x.title)});return 'bar on='+b.classList.contains('on')+' buttons='+t.join(',')})()"
press() {
    printf "%s" "(function(){var h=document.querySelector('[data-ghoztty-ui]');if(!h)return 'nobar';var b=h.shadowRoot.querySelector('button[title=$1]');if(!b)return 'nobutton';b.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,composed:true}));return 'pressed $1 sel='+JSON.stringify(String(getSelection()))})()"
}
BLOCKS="(function(){var q=document.querySelectorAll('#c .q');var o=[];q.forEach(function(n){o.push(n.getAttribute('data-qid')+':'+n.textContent)});return 'blocks '+q.length+' '+o.join('|')})()"
DEL="(function(){var c=document.getElementById('c');var q=c.querySelector('.q');if(!q)return 'noblock';q.remove();c.dispatchEvent(new Event('input',{bubbles:true}));return 'deleted'})()"

steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
feedback
composer
probe $(sel 'quick brown fox')
sleep 250
probe $BAR
probe $(press Quote)
sleep 300
composer
composer-probe $BLOCKS
probe $BAR
composer-type my note about it
sleep 400
probe $(sel 'river bank')
sleep 250
probe $(press Quote)
sleep 500
composer
composer-probe $BLOCKS
probe $(sel 'lazy dog')
sleep 250
probe $(press Copy)
sleep 300
composer-key ctrl+Enter
composer
sleep 2500
composer
probe $(sel 'quick brown fox')
sleep 250
probe $(press Quote)
sleep 300
composer
composer-probe $DEL
sleep 300
composer-type after deleting it
sleep 400
composer
composer-key ctrl+Enter
composer
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
hl_check "Q3 the app serves its socket" $?

o=$(cli +split --view="$repo/docs/doc.md" --name=doc 2>&1)
hl_check "Q4 +split --view=<repo file> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK In Repo" ]
hl_check "Q5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 150 grep -qs '^done' "$out"
hl_check "Q6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
co() { nth 'composer ' "$1"; }
pr() { nth 'probe ' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(co 1)
has "$s" "open=false view=false" && has "$s" "quotes=0"
hl_check "Q7 before any quote the composer is closed and empty" $? "$s"

[ "$(pr 1)" = "probe OK sel quick brown fox" ]
hl_check "Q8 the page's text is selected" $? "$(pr 1)"

s=$(pr 2)
has "$s" "bar on=true buttons=Quote,Copy"
hl_check "Q9 the selection shows the shared toolbar with Quote and Copy (the script reached the GTK page)" $? "$s"

s=$(pr 3)
has "$s" "pressed Quote"
hl_check "Q10 Quote is pressed" $? "$s"

s=$(co 2)
has "$s" "open=true view=true ready=true" && has "$s" "quotes=1 quoted=1" && has "$s" 'text=quick brown fox\n\n'
hl_check "Q11 Quote opens the composer with the passage as its own block, the caret below it" $? "$s"

s=$(nth 'probe ' 4)
has "$s" "blocks 1 1:quick brown fox"
hl_check "Q12 the composer page built the quote as a block carrying its id (T935)" $? "$s"

s=$(pr 5)
has "$s" "bar on=false"
hl_check "Q13 the toolbar hides and the page selection is cleared after quoting" $? "$s"

s=$(co 3)
# The shared composer page folds one newline under a quote block into the
# block's own boundary when the user types below it, so the note follows
# after one or two; the second block then goes in after a blank line.
has "$s" "quotes=2 quoted=2" && has "$s" 'text=quick brown fox\n' && has "$s" 'my note about it\n\nriver bank\n\n'
hl_check "Q14 a second Quote into the OPEN composer lands at the caret after the typed note; both blocks stay live" $? "$s"

s=$(pr 8)
has "$s" "blocks 2 1:quick brown fox|2:river bank"
hl_check "Q15 the open page was re-seeded with both blocks and their ids" $? "$s"

grep -qx "copy lazy dog" "$links" 2>/dev/null
hl_check "Q16 Copy puts the selection on the clipboard (GDK, through copyText)" $? "$(cat "$links" 2>/dev/null | tr '\n' ' ')"

s=$(co 4)
has "$s" "sends=1" && has "$s" "quotes=0" && has "$s" "status=Filed temp/feedback/new/"
hl_check "Q17 Ctrl+Enter files the report and the composer clears its quotes with its text" $? "$s"

s=$(co 5)
has "$s" "open=false view=false"
hl_check "Q18 the composer closes after Filed" $? "$s"

s=$(co 6)
has "$s" "open=true" && has "$s" "quotes=1 quoted=3"
hl_check "Q19 quoting again reopens the composer with the new block" $? "$s"

s=$(co 7)
has "$s" "quotes=0 quoted=3" && has "$s" "after deleting it"
hl_check "Q20 deleting the block in the composer drops it from the live quotes" $? "$s"

s=$(co 8)
has "$s" "sends=2"
hl_check "Q21 the second report files" $? "$s"

# ---- the reports on disk -----------------------------------------------------
n=$(find "$queue" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$n" = 2 ]
hl_check "Q22 exactly two report folders landed" $? "found $n"

first=$(ls "$queue" 2>/dev/null | sort | head -1)
second=$(ls "$queue" 2>/dev/null | sort | sed -n 2p)
check_first() {
    python3 - "$queue/$first/report.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
q = r.get("quotes") or []
bad = []
def want(name, cond):
    if not cond: bad.append(name)
want("count", len(q) == 2)
if len(q) == 2:
    a, b = q
    want("a.text", a.get("text") == "quick brown fox")
    want("a.headingId", a.get("headingId") == "second-part")
    want("a.headingText", a.get("headingText") == "Second Part")
    want("a.blockSelector", "p:nth-of-type(" in (a.get("blockSelector") or ""))
    want("a.blockText", a.get("blockText") == "The quick brown fox jumps over the lazy dog.")
    want("a.offsetInBlock", a.get("offsetInBlock") == 4)
    want("a.documentOffset", isinstance(a.get("documentOffset"), int) and a["documentOffset"] > 4)
    want("a.sourceLine", a.get("sourceLine") == 7)
    want("b.text", b.get("text") == "river bank")
    want("b.sourceLine", b.get("sourceLine") == 9)
    want("b.offsetInBlock", b.get("offsetInBlock") == 23)
body = r.get("body") or ""
want("body.quoteA", "> quick brown fox" in body)
want("body.note", "my note about it" in body)
want("body.quoteB", "> river bank" in body)
want("kind", r["source"].get("kind") == "file")
print("bad=" + ",".join(bad) + " :: " + json.dumps(q)[:600] + " body=" + json.dumps(body) if bad else "ok")
PY
}
res=$(check_first 2>&1)
[ "$res" = ok ]
hl_check "Q23 report 1 carries both quotes with headingId/Text, blockSelector/Text, offsets and sourceLine 7 and 9; the body quotes them as markdown" $? "$res"

check_second() {
    python3 - "$queue/$second/report.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("quotes") == [] and (r.get("body") or "").strip() == "after deleting it"
print("ok" if ok else "quotes=" + json.dumps(r.get("quotes")) + " body=" + json.dumps(r.get("body")))
PY
}
res=$(check_second 2>&1)
[ "$res" = ok ]
hl_check "Q24 report 2: the deleted block's metadata is gone" $? "$res"

grep -q "viewer quote id=1 bytes=15 heading=second-part block=" "$APP_LOG"
hl_check "Q25 the app logged the quote with its recorded context" $? "$(grep 'viewer quote' "$APP_LOG" | head -3 | tr '\n' ' ')"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "Q26 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
