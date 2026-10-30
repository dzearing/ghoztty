"""Single-frame flashes in a region of a capture (T2485 anomaly a): a frame
that differs from BOTH neighbours while the neighbours agree with each other
is a blink, not motion.  score = (d(p,c) + d(c,n)) / 2 - d(p,n), mean abs
luminance difference per pixel over the region.
usage: python flash.py <run dir> <first> <last> <x0> <x1> [y0 y1] [threshold]"""
import sys
from PIL import Image, ImageChops, ImageStat
d = sys.argv[1]; a, b = int(sys.argv[2]), int(sys.argv[3]); x0, x1 = int(sys.argv[4]), int(sys.argv[5])
y0, y1 = (int(sys.argv[6]), int(sys.argv[7])) if len(sys.argv) > 7 else (60, 900)
th = float(sys.argv[8]) if len(sys.argv) > 8 else 3.0
def ld(i):
    try: return Image.open('%s/frames/f%06d-sample.png' % (d, i)).convert('L').crop((x0, y0, x1, y1))
    except Exception: return None
def df(p, q): return ImageStat.Stat(ImageChops.difference(p, q)).mean[0]
fr = {i: ld(i) for i in range(a - 1, b + 2)}
for i in range(a, b + 1):
    p, c, n = fr[i - 1], fr[i], fr[i + 1]
    if p is None or c is None or n is None: continue
    s = (df(p, c) + df(c, n)) / 2 - df(p, n)
    if s > th: print('f%d flash %.1f  (p-c %.1f c-n %.1f p-n %.1f) mean %.0f vs %.0f' % (i, s, df(p, c), df(c, n), df(p, n), ImageStat.Stat(c).mean[0], ImageStat.Stat(p).mean[0]))
