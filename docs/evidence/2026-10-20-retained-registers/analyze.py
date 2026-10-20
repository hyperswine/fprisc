from pathlib import Path
import re, json, hashlib
out=Path('docs/evidence/2026-10-20-retained-registers')

def roots(run, name):
    return sorted(Path('build/'+run+'/cache/fpr/build').glob(name+'-*.s'),key=lambda p:p.stat().st_mtime)
def files(root):
    return [root]+[Path(p) for p in Path(str(root)+'.units').read_text().splitlines()]
def normalize(text):
    text=re.sub(r'g(?:61|65)(?=-|rt)', 'gREV', text)
    def data(m):
        b=bytes(int(x.strip()) for line in m[0].splitlines() for x in line.strip().removeprefix('.byte').strip().split(','))
        b=b.replace(b'fpr-interface-1/g61/',b'fpr-interface-1/gREV/').replace(b'fpr-interface-1/g65/',b'fpr-interface-1/gREV/')
        return '    .bytes '+b.hex()+'\n'
    return re.sub(r'(?:^    \.byte [^\n]*\n)+',data,text,flags=re.M)
parity={}
for name in ['fib','sum','pipeline','byteloop','helpers','sha']:
    old=files(roots('cleaned-registers-measurement',name)[0])
    new=files(roots('retained-registers-final',name)[0])
    assert len(old)==len(new)
    matches=[]
    for a,b in zip(old,new):
        x,y=normalize(a.read_text()),normalize(b.read_text())
        if x!=y:
            import difflib
            Path('build/retained-parity-diff.txt').write_text(''.join(difflib.unified_diff(x.splitlines(True),y.splitlines(True))))
        assert x==y, (name,a,b)
        matches.append({'old_file':str(a),'new_file':str(b),'normalized_sha256':hashlib.sha256(x.encode()).hexdigest()})
    parity[name]=matches
(out/'default-parity-g61-g65.json').write_text(json.dumps({'normalization':'Compiler revision in cache namespace and fpr-interface metadata; canonical byte line wrapping only','comparisons':parity},indent=2)+'\n')
wcet={}
for run in ['retained-registers-final','retained-registers-combined']:
    if not (Path('build')/run/'results.json').exists():continue
    programs={}
    for name in ['fib','sum','pipeline','byteloop','helpers','sha']:
        tables=[]
        for root in roots(run,name):
            table={}
            for f in files(root):
                for n,v in re.findall(r'^# wcet: (\S+) segmax=(\S+)',f.read_text(),re.M):
                    n=n.replace('-retainedregs','').replace('-selfloops','')
                    assert v!='UNBOUNDED',(run,name,n)
                    table[n]=int(v)
            tables.append(table)
        a,b=tables;assert a.keys()==b.keys()
        programs[name]={'functions':len(a),'maximum_off':max(a.values()),'maximum_on':max(b.values()),'increases':{n:[v,b[n]] for n,v in a.items() if b[n]>v},'decreases':{n:[v,b[n]] for n,v in a.items() if b[n]<v}}
    wcet[run]=programs
(out/'wcet.json').write_text(json.dumps(wcet,indent=2)+'\n')
print('default parity:',sum(map(len,parity.values())),'assembly files identical after revision normalization')
for run,programs in wcet.items():print(run,{k:(v['maximum_off'],v['maximum_on']) for k,v in programs.items()})
