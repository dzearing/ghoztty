#!/usr/bin/env bash
# viewer-glass-scheme.sh - T3720 acceptance: on a glass pane a template viewer
# page (markdown here) takes its light/dark from the terminal background its
# ink sits over, not from the desktop. win32 `viewer_glass.pageScheme`
# (T1885); Mac's window appearance follows the terminal background. GTK's
# WebKit follows the app's libadwaita style, which a dark desktop (stood in
# for by the debug `style dark` step) turns dark even over a light terminal,
# so the page holds the scheme itself (src/apprt/gtk/viewer_glass_scheme.zig).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-glass-scheme.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the
# debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig).
# Each `mark` is a sync point: the script rewrites the config and reloads,
# then the steps' following `sleep` lets the pane re-sync before the probe.
#
# Output: one PASS/FAIL line per check, then 'VIEWER GLASS SCHEME: ALL PASS' or
# 'VIEWER GLASS SCHEME: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER GLASS SCHEME"

log=/tmp/viewer-glass-scheme-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "V1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "V2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# A LIGHT terminal on glass. window-theme = auto would merely prefer light;
# the `style dark` step then plays the dark desktop that wins over it.
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
light_cfg='background = #f0f0f0\nforeground = #202020\nbackground-opacity = 1\nmacos-pane-glass = true\n'
printf "$light_cfg" > "$cfg_dir/config.ghostty"

doc="$HL_RUNTIME/scheme.md"
printf '# Scheme\n\nSome body text.\n' > "$doc"

# The page's ink, and the scheme the page says it holds.
INK="(function(){var e=document.querySelector('.markdown-body')||document.body;return getComputedStyle(e).color+'|'+((window.__gzScheme||{}).s||'os')})()"
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
sleep 2500
style dark
sleep 800
probe $INK
mark glass-off
sleep 4000
probe $INK
mark dark-bg
sleep 4000
style light
sleep 800
probe $INK
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="(function(){var h=document.querySelector('h1');return h?h.textContent:'NOH1'})()"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'exec sleep 600'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "V3 the app serves its socket" $?

o=$(cli +split --view="$doc" --name=sv 2>&1)
hl_check "V4 +split --view=<markdown> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Scheme" ]
hl_check "V5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

# mark glass-off: the same light terminal, glass off (the control).
hl_wait_for 40 grep -qs '^mark glass-off' "$out"
printf "${light_cfg}macos-pane-glass = false\n" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1
# mark dark-bg: glass back on over a DARK terminal, then a light app style.
hl_wait_for 40 grep -qs '^mark dark-bg' "$out"
printf "${light_cfg}background = #203040\nforeground = #e0e0e0\n" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1

hl_wait_for 60 grep -qs '^done' "$out"
hl_check "V6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
# rgb(r, g, b) -> the channel sum, so "dark ink" and "light ink" need no exact theme.
lum() { echo "$1" | sed -n 's/.*rgb(\([0-9]*\), *\([0-9]*\), *\([0-9]*\)).*/\1 \2 \3/p' | awk '{print $1+$2+$3}'; }
ink() { nth probe "$1" | sed 's/^probe OK //'; }

p1=$(ink 1); i1=$(lum "${p1%%|*}")
[ "${i1:-999}" -lt 300 ] && [ "${p1#*|}" = light ]
hl_check "V7 on glass over a light terminal, under a dark app style, the page holds light: dark ink on the light sheet" $? "$p1"

p2=$(ink 2); i2=$(lum "${p2%%|*}")
[ "${i2:-0}" -gt 450 ] && [ "${p2#*|}" = os ]
hl_check "V8 control: off glass the same page follows the dark app style again (light ink) - the scheme is released" $? "$p2"

p3=$(ink 3); i3=$(lum "${p3%%|*}")
[ "${i3:-0}" -gt 450 ] && [ "${p3#*|}" = dark ]
hl_check "V9 back on glass over a dark terminal (a reload), under a light app style, the page holds dark: light ink" $? "$p3"

hl_finish "$L"
