"""Stack one text band (y 58-110, full width) of consecutive frames, one row
per frame, labelled - the quickest way to see doubled/offset glyphs (A3) and
panes jumping across a whole fold.

usage: python rows.py <run dir> <first> <last> <out.png> [y0 y1]
"""
import sys
from PIL import Image, ImageDraw
d, a, b, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
y0, y1 = (int(sys.argv[5]), int(sys.argv[6])) if len(sys.argv) > 6 else (58, 110)
ims = []
for i in range(a, b + 1):
    im = Image.open('%s/frames/f%06d-sample.png' % (d, i)).convert('RGB')
    im = im.crop((480, y0, im.width, y1))
    ImageDraw.Draw(im).text((2, 2), 'f%d' % i, fill=(255, 255, 0))
    ims.append(im)
m = Image.new('RGB', (ims[0].width, sum(i.height + 2 for i in ims)), (255, 0, 255))
y = 0
for i in ims:
    m.paste(i, (0, y)); y += i.height + 2
m.save(out)
