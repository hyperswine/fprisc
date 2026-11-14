import sys,subprocess,re,bisect
cg,binp=sys.argv[1],sys.argv[2]
syms=[]
for l in subprocess.run(['nm','-n',binp],capture_output=True,text=True).stdout.splitlines():
    p=l.split()
    if len(p)==3 and p[1] in 'Tt': syms.append((int(p[0],16),p[2]))
addrs=[a for a,_ in syms]
out=subprocess.run(['callgrind_annotate',cg],capture_output=True,text=True).stdout
agg={}
tot=None
for l in out.splitlines():
    m=re.match(r'\s*([\d,]+) \(\s*[\d.]+%\)\s+\?\?\?:(\S+)',l)
    if not m: 
        m2=re.match(r'\s*([\d,]+) \(100.0%\)\s+PROGRAM TOTALS',l)
        if m2: tot=int(m2.group(1).replace(',',''))
        continue
    ir=int(m.group(1).replace(',','')); f=m.group(2)
    if f.startswith('0x'):
        a=int(f.split("'")[0],16); i=bisect.bisect_right(addrs,a)-1; f=syms[i][1] if i>=0 else f
    f=re.sub(r'_x40[0-9a-f]+$','',f.split("'")[0])
    agg[f]=agg.get(f,0)+ir
print('total',tot)
for f,ir in sorted(agg.items(),key=lambda x:-x[1])[:int(sys.argv[3]) if len(sys.argv)>3 else 12]:
    print(f'{ir/1e6:10.1f}M  {f}')
