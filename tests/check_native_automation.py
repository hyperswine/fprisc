#!/usr/bin/env python3
"""Native automation acceptance. External Git is only the independent test oracle.
Applications run with an empty executable PATH; all state is disposable.
"""
import json, os, subprocess, tarfile, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
ENV = {**os.environ, 'SOL_JIT':'0', 'SOL_GPU':'0', 'SOL_TABLE':'0',
       'XDG_CACHE_HOME':'/private/tmp/fpr-pure-cache'}
def command(argv, **kwargs):
    r = subprocess.run(list(map(str,argv)), capture_output=True, text=True, timeout=90, **kwargs)
    assert r.returncode == 0, (argv,r.stdout,r.stderr)
    return r.stdout.strip()
def git(repo,*args):
    return command(['git','-C',repo,*args])
with tempfile.TemporaryDirectory(prefix='fpr-native-automation-') as tmp:
    w=Path(tmp); native={**ENV,'PATH':'/nonexistent','SOL_CACHE_DIR':str(w/'cache')}
    counter=0
    def sol(body, *, ok=True, extra=None, script=None, args=()):
        global counter
        counter+=1
        p=script or w/f'case{counter}.sol'
        if not script: p.write_text(body)
        r=subprocess.run([str(FPR),'sol',str(p),*map(str,args)], env=native|(extra or {}),
                         capture_output=True,text=True,timeout=60,cwd=w)
        assert (r.returncode==0)==ok,(body,r.stdout,r.stderr)
        return r
    G=f'G = use "{ROOT}/sol/lib/git.sol".\n'
    A=f'A = use "{ROOT}/sol/lib/archive.sol".\n'
    repo=w/'repo with spaces'; repo.mkdir(); (repo/'hello.txt').write_text('hello\n')
    r=f'(G.repo "{repo}" |> G.identity "Native Test" "native@example.invalid")'
    sol(G+f'> r = {r} |> G.initOn "main" |> G.add G.all |> G.commit "first" |> G.branch "feature" |> G.tag "v1"; log "done".', extra={'SOL_FORCE_RETRY':'1'})
    assert git(repo,'rev-list','--count','HEAD')=='1'
    head=git(repo,'rev-parse','HEAD')
    sol(G+f'> u1 = print (G.head {r}); u2 = print (G.log 0 {r}); print (G.status {r}).')
    (repo/'hello.txt').write_text('changed\n')
    assert '+changed' in sol(G+f'> print (G.diff {r}).').stdout
    limited=sol(f'> print (NativeGit.query 1 "{repo}" GitDiff).')
    assert 'Err native Git output limit' in limited.stdout
    sol(G+f'> print ({r} |> G.add (G.paths ["hello.txt"])).')
    assert '+changed' in sol(G+f'> print (G.diffStaged {r}).').stdout
    sol(G+f'> print ({r} |> G.unadd (G.paths ["hello.txt"])).')
    assert git(repo,'diff','--cached')==''
    sol(G+f'> print ({r} |> G.add G.updated |> G.commit "second" |> G.uncommit G.keepWorktree).')
    assert git(repo,'rev-parse','HEAD')==head and git(repo,'diff','--cached')==''
    # Branch switching and deletion preserve local work and unmerged commits.
    sol(G+f'> print ({r} |> G.add G.all |> G.commit "second" |> G.branch "ahead" |> G.switch "feature").')
    assert git(repo,'branch','--show-current')=='feature'
    (repo/'hello.txt').write_text('do not lose\n')
    sol(G+f'> print ({r} |> G.switch "main").',ok=False)
    assert git(repo,'branch','--show-current')=='feature' and (repo/'hello.txt').read_text()=='do not lose\n'
    (repo/'hello.txt').write_text('hello\n')
    sol(G+f'> print ({r} |> G.deleteBranch "ahead").',ok=False)
    assert git(repo,'show-ref','refs/heads/ahead')
    sol(G+f'> print ({r} |> G.switch "main" |> G.untag "v1" |> G.deleteBranch "feature").')
    # All mutations remain deferred on script panic; no repository is created.
    absent=w/'not-created'
    sol(G+f'> r = G.repo "{absent}" |> G.init; error "abort".',ok=False)
    assert not absent.exists()
    bare=w/'remote.git';command(['git','init','--bare','-q',bare]);git(repo,'remote','add','origin',str(bare))
    sol(G+f'> print (G.push "origin" "main" {r}).')
    before=git(bare,'rev-parse','main')
    (repo/'third.txt').write_text('third')
    out=sol(G+f'> r = {r} |> G.add G.all |> G.commit "third"; print (G.pushNow "origin" "main" r).')
    assert 'Err Git.push' in out.stdout and git(bare,'rev-parse','main')==before
    # A failed native effect fences subsequent native effects.
    sol(G+f'> r = {r} |> G.branch "main" |> G.tag "must-not-exist"; print "queued".',ok=False)
    assert 'must-not-exist' not in git(repo,'tag')
    # Archives stream binary content, directories and symlinks without following.
    tree=w/'source';tree.mkdir();(tree/'nested').mkdir();(tree/'nested'/'bytes.bin').write_bytes(bytes(range(256))*1024)
    (tree/'link').symlink_to('nested/bytes.bin');target=w/'archive.tar.gz'
    sol('',script=ROOT/'sol/scripts/archive.sol',args=[tree,target])
    with tarfile.open(target) as t:
        members=t.getmembers();regular=next(m for m in members if m.name.endswith('/bytes.bin'))
        assert t.extractfile(regular).read()==(tree/'nested'/'bytes.bin').read_bytes()
        assert next(m for m in members if m.name.endswith('/link')).issym()
    old=target.read_bytes()
    sol(A+f'> u = A.createWith (A.Limits 1 1) "{tree}" "{target}"; print "queued".',ok=False)
    assert target.read_bytes()==old and not list(w.glob('*.sol-archive.*'))
    sol(A+f'> u = A.create "{tree}" "{tree}/inside.tar.gz"; print "queued".',ok=False)
    assert not (tree/'inside.tar.gz').exists()
    leaked=w/'leaked.tar.gz'
    sol(A+f'> u = A.create "{tree}" "{leaked}"; error "abort".',ok=False)
    assert not leaked.exists()
    # Earlier writes land before the archive; retries discard uncommitted plans.
    note=w/'note.txt'; ordered=w/'ordered.tar.gz'
    sol(A+f'> u1 = writePath "{note}" "new contents"; u2 = A.create "{note}" "{ordered}"; log "queued".',extra={'SOL_FORCE_RETRY':'1'})
    with tarfile.open(ordered) as t: assert t.extractfile(next(m for m in t.getmembers() if m.name.endswith('/note.txt'))).read()==b'new contents'
    # Recovery serializes native operations and skips completed Git mutations.
    crash=w/'crash.sol'; crash.write_text(G+A+f'> r = {r} |> G.tag "recovered"; u = A.create "{note}" "{w}/recovered.tar.gz"; print "queued".')
    sol('',script=crash,ok=False,extra={'SOL_CRASH_AT':'1'})
    crash.write_text('> print "recovery".')
    sol('',script=crash)
    assert 'recovered' in git(repo,'tag') and (w/'recovered.tar.gz').is_file()
    # Base and compositional report metadata: loose, packed, detached, worktree.
    executables=[]
    for source in ['examples/report.fpr','examples/ideal/report.fpr']:
        exe=w/Path(source).parent.name
        command([FPR,'build',ROOT/source,'-o',exe],env=ENV)
        executables.append(exe)
    def report(path,expected):
        for exe in executables:
            for harts in ['1','4']:
                dest=w/'report.json'
                command([exe,path,dest],env=native|{'FPR_HARTS':harts})
                data=json.loads(dest.read_text());assert data['revision']==expected,(path,data)
    report(repo,git(repo,'rev-parse','HEAD'))
    git(repo,'pack-refs','--all');report(repo,git(repo,'rev-parse','HEAD'))
    nested=repo/'sub';nested.mkdir();report(nested,git(repo,'rev-parse','HEAD'))
    worktree=w/'worktree';git(repo,'worktree','add','--detach',str(worktree),'HEAD');report(worktree,git(repo,'rev-parse','HEAD'))
    git(repo,'checkout','--detach','-q');report(repo,git(repo,'rev-parse','HEAD'))
    empty=w/'empty';empty.mkdir();report(empty,None)
    git(bare,'symbolic-ref','HEAD','refs/heads/main');report(bare,git(bare,'rev-parse','main'))
    metadata=w/'metadata';(metadata/'.git'/'refs'/'heads').mkdir(parents=True)
    (metadata/'.git'/'HEAD').write_text('ref: refs/heads/a\n')
    (metadata/'.git'/'refs'/'heads'/'a').write_text('ref: refs/heads/a\n');report(metadata,None)
    (metadata/'.git'/'HEAD').write_text('invalid\n');report(metadata,None)
    (metadata/'.git'/'HEAD').write_text('a'*64+'\n');report(metadata,'a'*64)
    # Kernel facts with PATH disabled; requires normal host process-table access.
    system=sol('',script=ROOT/'sol/scripts/system-report.sol',args=[w/'system.txt'])
    text=(w/'system.txt').read_text();assert all(title in text for title in ['Date','Hostname','Operating system','Uptime','Disk usage','Processes'])
print('native automation: Git, archive, report, rollback/order/retry/recovery and empty-PATH acceptance passed')
