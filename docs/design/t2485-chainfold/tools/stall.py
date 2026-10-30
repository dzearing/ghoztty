"""Runs of 3+ identical frames (a stalled glide) in a capture.
usage: python stall.py <run dir> <first> <last>"""
import sys
from PIL import Image, ImageChops
d=sys.argv[1]; a,b=int(sys.argv[2]),int(sys.argv[3])
prev=None; runs=[]; cur=None; out=[]
for i in range(a,b+1):
    try: im=Image.open('%s/frames/f%06d-sample.png'%(d,i)).convert('L').crop((480,50,10**5,700))
    except Exception: out.append('f%d:missing'%i); prev=None; continue
    im=im.crop((0,0,min(im.width,1500),im.height))
    if prev is not None:
        bb=ImageChops.difference(im,prev).point(lambda v:255 if v>24 else 0).getbbox()
        same = bb is None
        if same: cur = (cur[0],i) if cur else (i-1,i)
        else:
            if cur and cur[1]-cur[0]>=2: runs.append(cur)
            cur=None
    prev=im
if cur and cur[1]-cur[0]>=2: runs.append(cur)
print('static runs >=3 frames:',' '.join('f%d-f%d'%r for r in runs))
print(' '.join(out))
