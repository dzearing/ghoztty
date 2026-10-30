import json,sys,re,os
import numpy as np
from PIL import Image
run,log,a,b=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
meta=json.load(open(os.path.join(run,'timeline.json'),encoding='utf-8-sig'))
F=meta['freq']
tl=sorted([t for t in meta['timeline'] if t['png'] and not t['sup']],key=lambda t:t['i'])
t0=tl[0]['qpc']
passes=[]
for ln in open(log,encoding='utf-8',errors='replace'):
    m=re.search(r'strip faces pass qpc=(\d+)',ln)
    if m: passes.append([int(m.group(1)),[]]); continue
    if passes and re.search(r'strip face|stack fold|stack unfold|surface erase|frame dropped|carries',ln):
        passes[-1][1].append(ln.strip().split(': ',1)[-1][:90])
pi=0
for t in tl:
    if t['i']<a or t['i']>b: continue
    im=np.asarray(Image.open(t['png']).convert('L'),dtype=np.int16)[60:]
    cnt=[int((im[:,x:x+32]>140).sum()) for x in range(1696,1984,32)]
    print('f%d t=%.1f bright=%s'%(t['i'],(t['qpc']-t0)*1000/F,cnt))
    for q,ev in passes:
        if t['qpc']-F*0.0167 < q <= t['qpc']:
            print('   pass %.1f: %s'%((q-t0)*1000/F,' | '.join(e for e in ev if 'erase' not in e)))
