"""Per-phase cost of the layout passes in a GHOZTTY_STACK_TRACE + GHOZTTY_PERF
app log (T2485): plan / placeGrid / EndDeferWindowPos / vacated-strip clear
from the `stack trace batch` + `stack trace cleared` QPC stamps, and the glide
tick cost and gap from `stack trace tick`.
usage: python phases.py <app-stderr.log> [...]"""
import re, sys, statistics


def q(v):
    v = sorted(v)
    return 'median %6.2f p90 %6.2f max %7.2f' % (statistics.median(v), v[int(len(v) * .9)], v[-1]) if v else '-'


for f in sys.argv[1:]:
    rows, ticks, last = [], [], None
    for l in open(f, encoding='utf-8', errors='replace'):
        m = re.search(r'stack trace batch qpc=(\d+) end=(\d+) plan=(\d+) grid=(\d+)', l)
        if m:
            last = [int(x) for x in m.groups()]
            continue
        m = re.search(r'stack trace cleared qpc=(\d+)', l)
        if m and last:
            b, e, p0, p1 = last
            if p0 and p1:
                rows.append(((p1 - p0) / 1e4, (b - p1) / 1e4, (e - b) / 1e4, (int(m.group(1)) - e) / 1e4))
            last = None
            continue
        m = re.search(r'stack trace tick gap_us=(\d+) cost_us=(\d+)', l)
        if m and int(m.group(1)):
            ticks.append((int(m.group(1)) / 1e3, int(m.group(2)) / 1e3))
    print(f, 'passes', len(rows), 'ticks', len(ticks))
    for i, n in enumerate(['plan', 'placeGrid', 'EndDefer', 'clearVacated']):
        print('  %-12s %s' % (n, q([r[i] for r in rows])))
    print('  %-12s %s' % ('tick gap', q([t[0] for t in ticks])))
    print('  %-12s %s' % ('tick cost', q([t[1] for t in ticks])))
