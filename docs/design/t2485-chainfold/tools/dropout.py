"""T2485 temporal dropout detector: a column bin whose bright-text count falls
to <25% of BOTH neighbour frames (each >= MIN) for one or two frames.
python -I dropout.py <run-dir>"""
import json, os, sys
import numpy as np
from PIL import Image

run = sys.argv[1]
BIN = 32
MIN = 60
meta = json.load(open(os.path.join(run, 'timeline.json'), encoding='utf-8-sig'))
geo = json.load(open(os.path.join(run, 'geometry.json'), encoding='utf-8-sig'))
F = meta['freq']
tl = sorted([t for t in meta['timeline'] if t['png'] and not t['sup']], key=lambda t: t['i'])
press = next((s['qpc'] for s in meta['stamps'] if s['flags'] & 1), None)
rel = next((s['qpc'] for s in meta['stamps'] if s['flags'] & 2), None)
last_move = None
px = None
for s in meta['stamps']:
    if (s['x'], s['y']) != px:
        last_move = s['qpc']; px = (s['x'], s['y'])
t0 = tl[0]['qpc']
ms = lambda q: (q - t0) * 1000.0 / F if q else -1
top = geo['panes'][0]['Y'] - geo['window'][1] + 4
prof, black, idx, tms = [], [], [], []
for t in tl:
    a = np.asarray(Image.open(t['png']).convert('L'), dtype=np.int16)[top:]
    txt = a > 140
    W = a.shape[1] // BIN * BIN
    prof.append(txt[:, :W].reshape(a.shape[0], -1, BIN).sum(axis=(0, 2)))
    # solid-black wide region: columns whose max luminance < 12
    colmax = a.max(axis=0)
    run_, best = 0, 0
    for v in colmax:
        run_ = run_ + 1 if v < 12 else 0
        best = max(best, run_)
    black.append(best)
    idx.append(t['i']); tms.append(ms(t['qpc']))
P = np.array(prof)
print(f'frames={len(tl)} press={ms(press):.0f}ms lastmove={ms(last_move):.0f}ms release={ms(rel):.0f}ms')
hits = []
for k in range(1, len(P) - 1):
    for b in range(P.shape[1]):
        lo, hi = P[k - 1, b], P[k + 1, b]
        # allow a 2-frame dropout too
        hi2 = P[k + 2, b] if k + 2 < len(P) else 0
        ref = min(lo, max(hi, hi2))
        if ref >= MIN and P[k, b] < 0.25 * ref:
            hits.append((k, b))
byframe = {}
for k, b in hits:
    byframe.setdefault(k, []).append(b * BIN)
for k in sorted(byframe):
    xs = byframe[k]
    print(f'DROPOUT f{idx[k]} t={tms[k]:.0f}ms dt={tms[k]-tms[k-1]:.1f} bins={len(xs)} x={xs[0]}..{xs[-1]+BIN}')
bl = [(idx[k], tms[k], black[k]) for k in range(len(black)) if black[k] > 40]
for i, t, w in bl:
    print(f'BLACKRUN f{i} t={t:.0f}ms width={w}px')
gaps = [(idx[k], tms[k], tms[k] - tms[k - 1]) for k in range(1, len(tms)) if tms[k] - tms[k - 1] > 16.7]
print(f'gaps>16.7ms: {len(gaps)} (includes PNG-queue drops)')
