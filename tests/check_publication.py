#!/usr/bin/env python3
"""Publish real host images, poll snapshots and keep running across refusals."""
import os, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'

def run(args, cwd, ok=True, env=None):
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=env,
                       text=True, capture_output=True, timeout=180)
    assert (p.returncode == 0) == ok, p.stdout+p.stderr
    return p.stdout+p.stderr

def wait_for(pred):
    end = time.monotonic()+90
    while time.monotonic() < end:
        if pred(): return
        time.sleep(.1)
    raise AssertionError('watch timeout')

with tempfile.TemporaryDirectory(prefix='fpr-publication space-') as tmp:
    d = Path(tmp); source = d/'math.fpr'
    source.write_text('mathOp v = v * 2.\n')
    run([FPR,'watch',source,'--once'],d)
    journal = next((d/'.fpr').glob('publications.*.tsv'))
    initial = journal.read_bytes(); first = journal.read_text().strip('\n').split('\t')
    assert len(first)==5 and first[2]=='' and Path(first[4]).is_file(), first
    original_image=Path(first[4]).read_bytes()
    lock=d/'.fpr/publication.lock';lock.mkdir()
    run([FPR,'publish',source],d,False)
    assert journal.read_bytes()==initial
    lock.rmdir()
    run([FPR,'publish',source],d)
    assert journal.read_bytes()==initial, 'duplicate publication'
    source.write_text('mathOp v = missing v.\n')
    run([FPR,'publish',source],d,False)
    assert journal.read_bytes()==initial
    source.write_text('mathOp v = strlen v.\n')
    run([FPR,'publish',source],d,False)
    assert journal.read_bytes()==initial
    source.write_text('mathOp v = v * 3.\n')
    run([FPR,'publish',source],d,False,{**os.environ,'FPR_CC':'false'})
    assert journal.read_bytes()==initial and Path(first[4]).is_file()
    assert not list((d/'.fpr/store').glob('.module-build*'))
    run([FPR,'publish',source],d)
    second=journal.read_text().splitlines()[1].split('\t')
    assert second[2]==first[3] and second[3]!=first[3] and Path(second[4]).is_file()
    # Actual reader uses publication cursor and immutable path; loader checks
    # identities at the registry boundary. The old function remains callable.
    host=d/'host.fpr'
    host.write_text('''unsafe base.
W = use "std/watch".
N = use "std/native".
R = use "std/reload".
ok r = case r of Ok x -> x | Err why -> error why.
refuse r = case r of Err why -> Unit | Ok x -> error "accepted bad cursor or row".
await me port deadline =
  evs = MV.eventEvs me port;
  case evs of
    Nil -> (case Sys.mtime Unit > deadline of True -> error "worker timeout" | False -> Sys.sleepUs 10000 >> await me port deadline)
  | MV.EReload info :: Nil -> info
  | _ -> error "unexpected worker events".
main =
  _ = ok (N.attach "FIRST");
  old = R.bindAt 0 "mathOp";
  result = ok (W.poll "JOURNAL" "math" 1);
  (cursor, candidates) = result;
  candidate = case candidates of c :: Nil -> c | _ -> error "wrong events";
  info = W.identity candidate;
  ev = W.event candidate;
  _ = case ev of MV.EReload i -> Unit | _ -> error "wrong event";
  table = ok (N.loadVersionAt 0 info.from info.to (W.image candidate));
  op = R.bindAt table "mathOp";
  _ = case cursor == 2 and old 10 == 20 and op 10 == 30 of True -> Unit | False -> error "bad publication swap";
  _ = ok (W.poll "JOURNAL" "other" 0);
  _ = refuse (W.poll "JOURNAL" "math" 3);
  _ = refuse (W.poll "MALFORMED" "math" 0);
  port = spawn MV.eventsPort;
  worker = spawn (W.watch "JOURNAL" "math" 1 port);
  seen = await (myself 0) port (Sys.mtime Unit + 50000000);
  _ = case seen.to == info.to of True -> Unit | False -> error "worker wrong identity";
  _ = Sys.sleepUs 700000;
  extra = MV.eventEvs (myself 0) port;
  _ = case extra of Nil -> Unit | _ -> error "duplicate worker delivery";
  _ = kill worker;
  _ = kill port;
  print "publication poll: old=20 new=30 cursor=2 PASS".
MV = use "std/mvu".
'''.replace('FIRST',first[4]).replace('JOURNAL',str(journal)).replace('MALFORMED',str(d/'bad.tsv')))
    (d/'bad.tsv').write_text('bad row\n')
    exe=d/'host';run([FPR,'build',host,'-o',exe],d)
    for harts in ('1','4'):
        out=run([exe],d,env={**os.environ,'FPR_HARTS':harts})
        assert 'publication poll: old=20 new=30 cursor=2 PASS' in out,out
    # Publication worker -> typed event port -> MVU runner -> real loader.
    live=(ROOT/'tests/base/mvureload.fpr').read_text()
    live=live.replace('unsafe base.', 'unsafe base.\nW = use "std/watch".\nN = use "std/native".\nR = use "std/reload".\nok r = case r of Ok x -> x | Err why -> error why.')
    live=live.replace('env.factor','(env.op 1)')
    a=live.index('candidate info env =');b=live.index('info from to =',a)
    live=live[:a]+f'''candidate info env = case W.imageFor "{journal}" info.name info.to of
    Err why -> Err why
  | Ok path -> adopted info env (N.loadVersionAt env.table info.from info.to path).
adopted info env r = case r of
    Err why -> Err why
  | Ok table -> Ok {{env | op = R.bindAt table "mathOp", table = table, hash = info.to}}.
'''+live[b:]
    live=live.replace('0 -> send p (MV.EReload (info "v1" "v2")) >> send p (MV.EMsg "add" "")',
                       '0 -> send p (MV.EMsg "add" "")')
    live=live.replace('main =\n',f'main =\n  _ = ok (N.attach "{first[4]}");\n')
    live=live.replace('  rd = spawn (render p);',f'  result = ok (W.poll "{journal}" "math" 1);\n  _ = W.deliver p 1 (Ok result);\n  _ = MV.portSync (myself 0) p;\n  rd = spawn (render p);')
    live=live.replace('{factor = 2, hash = "v1", port = p}',f'{{op = R.bindAt 0 "mathOp", table = 0, hash = "{first[3]}", port = p}}')
    live=live.replace('info "v2" "bad"', f'info "{second[3]}" "bad"')
    src=d/'live.fpr';src.write_text(live);exe=d/'live';run([FPR,'build',src,'-o',exe],d)
    for harts in ('1','4'):
        out=run([exe],d,env={**os.environ,'FPR_HARTS':harts})
        assert 'reload: acc=11 refused=2' in out,out
        assert 'frame 0: [factor=3 acc=2] builds=1' in out,out
    # Real long-running watcher refuses a broken save, then recovers on the
    # next compatible save. No mtime assumption: both edits may share a tick.
    with (d/'watch.log').open('w') as log:
        proc=subprocess.Popen([str(FPR),'watch',str(source)],cwd=d,stdout=log,stderr=log)
        try:
            time.sleep(1)
            source.write_text('mathOp v = unknown v.\n')
            wait_for(lambda: 'previous image remains current' in (d/'watch.log').read_text())
            assert journal.read_text().count('\n')==2
            source.write_text('mathOp v = v * 4.\n')
            wait_for(lambda: journal.read_text().count('\n')==3)
            assert proc.poll() is None
        finally:
            proc.terminate();proc.wait(timeout=10)
    assert Path(first[4]).read_bytes()==original_image, 'old image overwritten'
    print('publication: images, cursor, one/four harts, compile/type/link refusal, watch recovery PASS')
