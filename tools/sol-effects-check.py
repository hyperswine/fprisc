#!/usr/bin/env python3
"""Deferred dataflow/recovery, durable path logs and guarded Git compensation."""
import collections
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT/'fpr'
ENV = {k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
ENV.update(SOL_JIT='0', SOL_GPU='0')
def literal(s): return json.dumps(str(s), ensure_ascii=False).replace('{', '\\{').replace('}', '\\}')
def proc(argv): return 'ProcessSpec ['+', '.join(map(literal,argv))+'] "" [] "" 3000'
def later(args): return 'Proc.later (ProcessSpec ['+', '.join(args)+'] "" [] "" 3000)'
def git(repo,*args):
    return subprocess.check_output(['git','-C',str(repo),*args],stderr=subprocess.PIPE,text=True).strip()
def run(path, source=None, *, code=0, env=None, cwd=None, relative=False):
    if source is not None:path.write_text(source)
    p=subprocess.run([FPR,'sol',path.name if relative else path],cwd=cwd or path.parent,env={**ENV,**(env or {})},capture_output=True,text=True,timeout=40)
    assert (p.returncode==code if code is not None else p.returncode!=0),(path,p.returncode,p.stdout,p.stderr)
    return p
with tempfile.TemporaryDirectory(prefix='sol-effects-') as directory:
    d=Path(directory)
    ENV["SOL_STATE_DIR"] = str(d/"state")
    journal_dir=d/"state"/hashlib.sha256(str(d/"pipe").encode()).hexdigest()
    # Closed projections preserve argv boundaries; deferred streams still forward once.
    out=d/'pipe.out'; script=d/'pipe.sol'
    src=f''' > first = {later(['Lit "/usr/bin/printf"', 'Lit "  alpha:beta gamma\\nsecond:tail\\n  "'])};
  text = Deferred.field ":" 2 (Deferred.line 1 (Deferred.trim (Deferred.out first)));
  {later(['Lit "/bin/sh"','Lit "-c"',literal('printf \'%s\' "$1" > "$2"').join(['Lit ', '']), 'Lit "_"','From text','Lit '+literal(out)])}.
'''
    p=run(script,src,env={'SOL_FORCE_RETRY':'2'});assert out.read_text()=='beta gamma' and p.stdout=='  alpha:beta gamma\nsecond:tail\n  ',(p.stdout,p.stderr)
    p=run(script, '> Proc.later (ProcessSpec [Lit "/bin/sh", Lit "-c", Lit "printf captured; printf child-error >&2"] "" [] "" 3000).\n')
    assert p.stdout=='captured' and p.stderr=='child-error',(p.stdout,p.stderr)
    # The producer's result must survive recovery without executing it again.
    count=d/'producer.count'; recovered=d/'recovered.out'
    src=f'''> a = {later(['Lit "/bin/sh"','Lit "-c"','Lit '+literal('printf x >> "$1"; printf original'),'Lit "_"','Lit '+literal(count)])};
  b = Deferred.out a;
  {later(['Lit "/bin/sh"','Lit "-c"','Lit '+literal('printf \'%s\' "$1" > "$2"'),'Lit "_"','From b','Lit '+literal(recovered)])}.
'''
    run(script,src,code=137,env={'SOL_CRASH_AT':'1'})
    journals=list(journal_dir.glob('run.soljournal.*'));assert any(p.read_text().startswith('SOLJ2\n') for p in journals if p.is_file())
    assert count.read_text()=='x' and not recovered.exists()
    run(script,'> print "recovered".\n');assert count.read_text()=='x' and recovered.read_text()=='original'
    # Existing SOLJ1 plans and integer completion receipts remain readable.
    legacy=d/'pipe.soljournal.99999999.legacy'
    legacy_target=d/'legacy.out'
    legacy.write_text('SOLJ1\n[EShell '+json.dumps('/usr/bin/touch '+str(d/'legacy-forbidden'))+', EWrite '+json.dumps(str(legacy_target))+' "legacy"]\nCOMMIT\n')
    Path(str(legacy)+'.done').write_text('0\n')
    run(script,'> print "legacy recovered".\n')
    assert legacy_target.read_text()=='legacy' and not (d/'legacy-forbidden').exists()
    elsewhere=d/'elsewhere';elsewhere.mkdir()
    src='> u = shq "printf shell > shell-relative"; v = Proc.afterCommit (ProcessSpec ["/bin/sh", "-c", "printf process > process-relative"] "" [] "" 3000); w = writePath "file-relative" "file"; logTo "log-relative" "audit".\n'
    (d/'file-relative').write_text('old')
    (d/'log-relative').write_text('before\n')
    run(script,src,code=137,env={'SOL_CRASH_AT':'0'},relative=True)
    owners=list(d.glob('*.sol-lock/owner'))
    assert owners and all(Path(p.read_text().splitlines()[1]).is_absolute() for p in owners)
    reader=elsewhere/'reader.sol'
    result=elsewhere/'reader-result'
    run(reader,f'> a = readPath {literal(d/"file-relative")}; b = readPath {literal(d/"log-relative")}; writePath "reader-result" (strcat a b).\n',relative=True)
    assert result.read_text()=='filebefore\naudit\n'
    run(script,'> print "recovered from elsewhere".\n',cwd=elsewhere)
    for name,text in [('shell-relative','shell'),('process-relative','process'),('file-relative','file'),('log-relative','before\naudit\n')]:
        assert (d/name).read_text()==text and not (elsewhere/name).exists()
    alias=d/'alias-log';alias.write_text('prefix\n')
    run(script,f'> old = readPath "alias-log"; u = writePath {literal(alias)} (strcat old "body\\n"); logTo "./alias-log" "entry".\n')
    assert alias.read_text()=='prefix\nbody\nentry\n'
    run(script,'> old = ls "."; u = mkdirp "newdir"; writePath "newdir/file" "nested".\n')
    assert (d/'newdir/file').read_text()=='nested'
    # A bad projection fences the consumer and the audit line, while files land.
    audit=d/'audit.log'; landed=d/'landed'; forbidden=d/'forbidden'
    src=f'''> a = {later(['Lit "/usr/bin/printf"','Lit "one"'])};
  x = Deferred.line 2 (Deferred.out a);
  b = {later(['Lit "/usr/bin/touch"','From x','Lit '+literal(forbidden)])};
  u = writePath {literal(landed)} "file";
  logTo {literal(audit)} "must not log".
'''
    p=run(script,src,code=None);assert not forbidden.exists() and landed.read_text()=='file' and not audit.exists()
    assert 'out of range' in p.stderr,p.stderr
    # Failed results remain failures after recovery (not just completed indices).
    src=f'''> u = Proc.afterCommit ({proc(['/bin/sh','-c','exit 7'])});
  v = writePath {literal(landed)} "after failure";
  w = Proc.afterCommit ({proc(['/usr/bin/touch',str(forbidden)])});
  logTo {literal(audit)} "must not log".
'''
    run(script,src,code=137,env={'SOL_CRASH_AT':'1'})
    run(script,'> print "recovered failed plan".\n');assert not forbidden.exists() and not audit.exists()
    assert landed.read_text()=='after failure'
    own=d/'own-log'
    run(script,f'> u = writePath {literal(own)} "prefix\\n"; logTo {literal(own)} "entry".\n')
    assert own.read_text()=='prefix\nentry\n'
    # Transactional append is serialized, retry-safe and idempotent on redo.
    src=f'> u = writePath {literal(landed)} "new"; logTo {literal(audit)} "once".\n'
    run(script,src,env={'SOL_FORCE_RETRY':'2'});assert audit.read_text()=='once\n'
    run(script,src,code=137,env={'SOL_CRASH_AT':'1'});assert audit.read_text()=='once\n'
    run(script,'> print "recovered log".\n');assert audit.read_text()=='once\nonce\n'
    clients=[]
    for i in range(4):
        path=d/f'log-{i}.sol';path.write_text(f'> logTo {literal(audit)} "writer-{i}".\n')
        clients.append(subprocess.Popen([FPR,'sol',path],cwd=d,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True))
    for p in clients:
        stdout,stderr=p.communicate(timeout=40);assert p.returncode==0,(stdout,stderr)
    assert collections.Counter(audit.read_text().splitlines())==collections.Counter(['once','once',*[f'writer-{i}' for i in range(4)]])
    run(script,f'> u = logTo {literal(audit)} "abort"; error "abort".\n',code=None)
    assert 'abort' not in audit.read_text()
    full=d/'nonempty';full.mkdir();(full/'child').write_text('keep')
    run(script,f'> u = rm {literal(full)}; logTo {literal(audit)} "bad remove".\n',code=None)
    assert (full/'child').exists() and 'bad remove' not in audit.read_text()
    # Existing mode preservation and explicit symlink refusal are conformance.
    mode=d/'executable';mode.write_text('old');mode.chmod(0o751)
    run(script,f'> writePath {literal(mode)} "new".\n');assert stat.S_IMODE(mode.stat().st_mode)==0o751
    link=d/'link';link.symlink_to(mode)
    run(script,f'> writePath {literal(link)} "bad".\n',code=None)
    assert link.is_symlink() and mode.read_text()=='new'
    run(script,f'> logTo {literal(link)} "bad".\n',code=None);assert link.is_symlink()
    print('Sol effects: closed projections, retry, captured-result recovery, failure fence, concurrent/idempotent path logs, modes and symlinks PASS',flush=True)
    # Only disposable local repositories and a local bare remote are used.
    repo=d/'repo';repo.mkdir();git(repo,'init','-q','-b','main');git(repo,'config','user.name','Sol Test');git(repo,'config','user.email','sol-test@example.invalid')
    (repo/'file').write_text('base');git(repo,'add','.');git(repo,'commit','-qm','base')
    lib=literal(ROOT/'sol/lib/git.sol');prefix=f'Git = use {lib}.\nr = Git.repo {literal(repo)}.\n'
    bare=d/'bare.git';subprocess.run(['git','init','--bare','-q',bare],check=True);git(repo,'remote','add','origin',str(bare))
    (repo/'file').write_text('next')
    src=prefix+'> added = Git.add Git.all r; committed = Git.commit "deferred" added; sha = Git.headLater committed; tagged = Git.tagAt "v1" sha committed; Git.push "origin" "main" tagged.\n'
    run(script,src);head=git(repo,'rev-parse','HEAD')
    assert git(repo,'rev-parse','v1')==head and git(bare,'rev-parse','main')==head
    (repo/'file').write_text('recover deferred Git')
    src=prefix.replace(literal(repo),literal('repo'))+'> added = Git.add Git.all r; committed = Git.commit "recover deferred" added; sha = Git.headLater committed; tagged = Git.tagAt "v2" sha committed; Git.push "origin" "main" tagged.\n'
    run(script,src,code=137,env={'SOL_CRASH_AT':'3'})
    recovered_head=git(repo,'rev-parse','HEAD')
    run(script,'> print "recovered Git dataflow".\n',cwd=elsewhere)
    assert git(repo,'rev-parse','v2')==recovered_head and git(bare,'rev-parse','main')==recovered_head
    run(script,prefix+'> p = Git.push "origin" "main" r; Git.tag "forbidden" p.\n',code=None)
    assert git(repo,'tag','--list','forbidden')==''
    # Abort and validation conflict restore only the captured ref; staged
    # changes survive so a retry can create the same logical commit again.
    (repo/'file').write_text('compensable');git(repo,'add','file');old=git(repo,'rev-parse','HEAD')
    immediate=prefix+'> sha = case Git.commitNow "immediate" r of Ok value -> value | Err why -> error why;\n'
    run(script,immediate+'error "abort".\n',code=None);assert git(repo,'rev-parse','HEAD')==old
    assert git(repo,'diff','--cached','--name-only')=='file'
    run(script,immediate+f'u = writePath {literal(landed)} sha; logTo {literal(audit)} "compensated retry".\n',env={'SOL_FORCE_RETRY':'2'})
    assert git(repo,'rev-list','--count',f'{old}..HEAD')=='1' and landed.read_text()==git(repo,'rev-parse','HEAD')
    # Deterministic crash windows before/after publication and the file commit point.
    for phase in ['prepared','published','anchored','completed']:
        old=git(repo,'rev-parse','HEAD');(repo/'file').write_text(phase);git(repo,'add','file')
        target=d/('state-'+phase)
        run(script,immediate+f'writePath {literal(target)} sha.\n',code=137,env={'SOL_SAGA_CRASH_AT':phase})
        new=git(repo,'rev-parse','HEAD')
        run(script,'> print "recovered saga".\n')
        if phase in ['prepared','published']:
            assert git(repo,'rev-parse','HEAD')==old and not target.exists(),phase
        else:assert git(repo,'rev-parse','HEAD')==new and target.read_text()==new,phase
        assert not list(journal_dir.glob('run.soljournal.*')),phase
    # Immediate pivots are refused while this inverse is armed.
    (repo/'file').write_text('pivot');git(repo,'add','file');old=git(repo,'rev-parse','HEAD')
    run(script,immediate+f'Proc.runNow ({proc(["/usr/bin/touch",str(forbidden)])}).\n',code=None)
    assert git(repo,'rev-parse','HEAD')==old and not forbidden.exists()
    # Concurrent foreign movement is preserved: never reset relative to HEAD.
    script.write_text(immediate+f'u = Proc.query ({proc(["/bin/sleep","2"])}); error "abort".\n')
    p=subprocess.Popen([FPR,'sol',script],cwd=d,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        until=time.monotonic()+30
        while git(repo,'rev-parse','HEAD')==old and time.monotonic()<until:time.sleep(.02)
        assert git(repo,'rev-parse','HEAD')!=old
        git(repo,'commit','--allow-empty','-qm','foreign');foreign=git(repo,'rev-parse','HEAD')
        stdout,stderr=p.communicate(timeout=30)
        assert p.returncode!=0 and 'compensation refused' in stderr,(stdout,stderr)
        assert git(repo,'rev-parse','HEAD')==foreign and list(journal_dir.glob('run.soljournal.*.undo'))
    finally:
        if p.poll() is None:p.kill();p.wait()
    print('Sol Git: deferred commit/head/tag/local push, terminal publication, CAS abort/retry, four crash windows and foreign-head refusal PASS',flush=True)
