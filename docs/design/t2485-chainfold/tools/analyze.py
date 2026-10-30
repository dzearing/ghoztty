"""T2485 offline analysis of a record-chainfold.ps1 run.

python -I analyze.py <run-dir> [--from N --to M] [--cols 6] [--scale 0.25]

Writes into <run-dir>:
  frames.csv      per kept frame: index, ms since first, ms since previous,
                  changed-pixel count vs previous, mean abs delta
  montage-*.png   contact sheets of frames [from, to], each labelled
  deltas-*.png    |frame - previous| heat maps for the same frames
"""
import json, os, sys, glob
import numpy as np
from PIL import Image, ImageDraw

run = sys.argv[1]
args = sys.argv[2:]
def opt(name, default):
    if name in args:
        return type(default)(args[args.index(name) + 1])
    return default

meta = json.load(open(os.path.join(run, 'timeline.json'), encoding='utf-8-sig'))
F = meta['freq']
tl = [t for t in meta['timeline'] if t['png'] and not t['sup']]
tl.sort(key=lambda t: t['i'])
t0 = tl[0]['qpc']
rows = []
prev = None
prevq = None
press = next((s['qpc'] for s in meta['stamps'] if s['flags'] & 1), None)
for t in tl:
    a = np.asarray(Image.open(t['png']).convert('RGB'), dtype=np.int16)
    if prev is not None and prev.shape == a.shape:
        d = np.abs(a - prev).max(axis=2)
        changed = int((d > 8).sum())
        mean = float(d.mean())
    else:
        changed, mean = -1, -1.0
    ms = (t['qpc'] - t0) * 1000.0 / F
    dms = (t['qpc'] - prevq) * 1000.0 / F if prevq else 0
    rows.append((t['i'], ms, dms, changed, mean))
    prev, prevq = a, t['qpc']

with open(os.path.join(run, 'frames.csv'), 'w') as f:
    f.write('index,ms,dms,changed,mean\n')
    for r in rows:
        f.write('%d,%.2f,%.2f,%d,%.3f\n' % r)
if press:
    print('press at %.1f ms' % ((press - t0) * 1000.0 / F))
gaps = [r for r in rows if r[2] > 16.7]
print('frames=%d gaps>16.7ms=%d max_gap=%.1f' % (len(rows), len(gaps), max(r[2] for r in rows)))

lo = opt('--from', 0); hi = opt('--to', 10**9)
cols = opt('--cols', 6); sc = opt('--scale', 0.25)
sel = [t for t in tl if lo <= t['i'] <= hi]
if '--montage' in args and sel:
    ims = [Image.open(t['png']).convert('RGB') for t in sel]
    w, h = ims[0].size
    tw, th = int(w * sc), int(h * sc)
    for kind in ('montage', 'deltas'):
        n = len(ims)
        sheet = Image.new('RGB', (cols * tw, ((n + cols - 1) // cols) * (th + 14)), (40, 40, 40))
        dr = ImageDraw.Draw(sheet)
        for k, (t, im) in enumerate(zip(sel, ims)):
            if kind == 'deltas':
                if k == 0:
                    continue
                d = np.abs(np.asarray(im, np.int16) - np.asarray(ims[k - 1], np.int16)).max(axis=2)
                im = Image.fromarray(np.clip(d * 4, 0, 255).astype(np.uint8)).convert('RGB')
            x, y = (k % cols) * tw, (k // cols) * (th + 14)
            sheet.paste(im.resize((tw, th)), (x, y + 14))
            dr.text((x + 2, y), 'f%d' % t['i'], fill=(255, 255, 0))
        sheet.save(os.path.join(run, '%s-%d-%d.png' % (kind, lo, min(hi, sel[-1]['i']))))
