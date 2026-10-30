import sys
from PIL import Image, ImageDraw
d, a, b, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
x0,x1,y0,y1 = 1550,2000,60,500
ims=[]
for i in range(a,b+1):
    im=Image.open('%s/f%06d-sample.png'%(d,i)).convert('RGB').crop((x0,y0,x1,y1))
    ImageDraw.Draw(im).text((4,4),'f%d'%i,fill=(255,255,0))
    ims.append(im)
W=sum(i.width for i in ims)+4*len(ims)
m=Image.new('RGB',(W,ims[0].height),(255,0,255))
x=0
for i in ims: m.paste(i,(x,0)); x+=i.width+4
m.save(out)
