"""Every placement batch of a GHOZTTY_STACK_TRACE app log put against a
capture's frames (T2485 D12): the first frame after the batch's end QPC, then
each card as p<order>:<x>/<width> with S shown / h hidden, C carried, and the
fold snap state (wa waiting, re ready).
usage: python bmap.py <app-stderr.log> <run dir>"""
import re,sys,json,bisect
log,run=sys.argv[1],sys.argv[2]
t=json.load(open(run+'/timeline.json',encoding='utf-8-sig'))
fq=[e['qpc'] for e in t['timeline']]; fi=[e['i'] for e in t['timeline']]
cur=[];order={}
for line in open(log,encoding='utf-8',errors='replace'):
    m=re.search(r'stack trace place hwnd=(\w+) .*?rect=(-?\d+),\d+\+(\d+)x\d+ card=(\S+) shown=(\w+) carried=(\w+).*?snap=(\w+) face=(\w+)',line)
    if m:
        h=m.group(1); order.setdefault(h,len(order))
        cur.append((order[h],int(m.group(2)),int(m.group(3)),m.group(5)[0],m.group(6)[0],m.group(7)[:2],m.group(8)[0])); continue
    m=re.search(r'stack trace batch qpc=(\d+) end=(\d+)',line)
    if m:
        e=int(m.group(2)); k=bisect.bisect_right(fq,e)
        f=fi[k] if k<len(fi) else -1
        print('f%-4d +%.1fms '%(f,(fq[k]-e)/1e4 if k<len(fq) else 0)+' '.join('p%d:%d/%d%s%s%s'%(o,x,w,'S' if s=='t' else 'h','C' if c=='t' else '',sn if sn!='no' else '') for o,x,w,s,c,sn,fa in sorted(cur)))
        cur=[]; continue
    for k in ('carries its frame','face first','strip face shown','divider drag run','replanned'):
        if k in line: print('   ',line.strip()[:140])
