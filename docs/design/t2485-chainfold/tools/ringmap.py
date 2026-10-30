"""T2485 D17: line the app's ring trace up against the captured frames.

  python ringmap.py <run dir> <app stderr log> <first frame> <last frame>

The app runs with GHOZTTY_STACK_TRACE=ring, so its stack trace lines are kept
in memory during the drag and written out after it (no ~7 ms a tick of log
writes distorting the glide, D16). Lines that carry qpc= (batch, cut, cleared,
face, faces retired, tick) are on the same clock as the frames in
timeline.json, so each frame is printed with every event that landed since the
frame before it - the place lines of a pass are printed with its batch.
"""
import json
import re
import sys

run, log, a, b = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
t = json.load(open(run + '/timeline.json', encoding='utf-8-sig'))
freq = t['freq']
frames = {f['i']: f['qpc'] for f in t['timeline']}

events = []  # (qpc, text)
pending = []  # place/card/plan lines waiting for their pass's batch stamp
for raw in open(log, encoding='utf-8', errors='replace'):
    line = raw.strip()
    i = line.find('stack trace ')
    if i < 0 or 'stack trace ring' in line:
        continue
    text = line[i + len('stack trace '):]
    m = re.search(r'\bqpc=(\d+)', text)
    if m is None:
        pending.append(text)
        continue
    q = int(m.group(1))
    if text.startswith('batch'):
        for p in pending:
            events.append((q, '  ' + p))
        pending = []
    events.append((q, text))
events.sort(key=lambda e: e[0])

prev = frames.get(a - 1, 0)
for i in range(a, b + 1):
    q = frames.get(i)
    if q is None:
        continue
    print('f%d  qpc=%d  (+%.1f ms)' % (i, q, (q - prev) * 1000.0 / freq))
    for eq, text in events:
        if prev < eq <= q:
            print('    %+6.1f ms  %s' % ((eq - q) * 1000.0 / freq, text[:200]))
    prev = q
