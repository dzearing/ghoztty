"""Near-black columns in a capture (T2485 D17 / A2 class): a column whose
pixels are pure black (max channel <= 6) on more than 60% of rows y150-850 is
a hole nothing painted, never the desk gradient or a dark pane face.
Positive control: run39 f142 reports 1795-1803.
usage: python blackcols.py <run dir> <first> <last>"""
import sys
from PIL import Image
import numpy as np
d = sys.argv[1]; a, b = int(sys.argv[2]), int(sys.argv[3])
for i in range(a, b + 1):
    try: im = np.asarray(Image.open('%s/frames/f%06d-sample.png' % (d, i)).convert('RGB')).astype(int)
    except Exception: continue
    blk = (im[150:850].max(axis=2) <= 6).mean(axis=0)
    cols = np.where(blk > 0.6)[0]
    if len(cols) == 0: continue
    runs = []; s = p = cols[0]
    for c in cols[1:]:
        if c != p + 1: runs.append((s, p)); s = c
        p = c
    runs.append((s, p))
    print('f%d' % i, ' '.join('%d-%d' % r for r in runs))
