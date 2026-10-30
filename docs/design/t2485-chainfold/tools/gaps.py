"""Batch-to-batch gaps from GHOZTTY_STACK_TRACE `stack trace batch` lines, and the gaps around each `face first` (T2485 D10/D11).
usage: python gaps.py <app-stderr.log>"""
import re,sys,statistics
qs=[];marks=[]
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    m=re.search(r'stack trace batch qpc=(\d+)',line)
    if m: qs.append(int(m.group(1)))
    if 'face first' in line: marks.append(len(qs))
g=[(qs[i+1]-qs[i])/10000 for i in range(len(qs)-1)]
print('batches',len(qs),'median %.1f p90 %.1f max %.1f'%(statistics.median(g),sorted(g)[int(len(g)*.9)],max(g)))
for k in marks: print('fold at batch',k,'gaps around:',' '.join('%.1f'%x for x in g[max(0,k-3):k+3]))
