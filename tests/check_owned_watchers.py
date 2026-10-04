#!/usr/bin/env python3
"""Runner-owned port/worker cleanup, startup refusal and independent inputs."""
import os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
base=(ROOT/'tests/base/mvureload.fpr').read_text()
helpers='''
Sys.alive : Int -> Bool .
starter parent port =
  worker = spawn (watcher parent port);
  _ = receiveFrom parent worker;
  _ = send parent (port, worker);
  Ok worker.
watcher parent port me =
  _ = send port (MV.EMsg "add" "");
  _ = MV.portSync me port;
  _ = send parent Unit;
  receive me.
refuseStart parent port = _ = send parent port; Err "watch unavailable".
'''
call='MV.runLive (myself 0) cfg app reload'
watched=base.replace(call,'expectOwned (myself 0) (MV.runWatched (myself 0) cfg app reload starter)')+helpers+'''
expectOwned me result =
  handles = receive me;
  (port, worker) = handles;
  _ = case Sys.alive port or Sys.alive worker of True -> error "owned actors survived" | False -> Unit;
  case result of Ok text -> text | Err why -> error why.
'''
early=watched.replace('MV.EMsg tag arg -> onMsg env m tag','MV.EResize w h -> (m, MV.MQuit :: Nil)\n  | MV.EMsg tag arg -> onMsg env m tag')
refused=base.replace(call,'expectStartFailure (myself 0) (MV.runWatched (myself 0) cfg app reload refuseStart)')+helpers+'''
expectStartFailure me result =
  port = receive me;
  _ = case Sys.alive port of True -> error "refused startup leaked port" | False -> Unit;
  case result of Err why -> why | Ok text -> error "startup accepted".
'''
with tempfile.TemporaryDirectory(prefix='owned-watch-') as tmp:
    for name,src,expect in [('owned',watched,'reload: acc=13 refused=2 [mvu: 3 frames, 2 statics builds]'),
                            ('initialquit',early,'reload: acc=0 refused=0 [mvu: 0 frames, 0 statics builds]'),
                            ('refused',refused,'watch unavailable')]:
        p=Path(tmp)/f'{name}.fpr';p.write_text(src);exe=Path(tmp)/name
        built=subprocess.run([ROOT/'fpr','build',p,'-o',exe],capture_output=True,text=True,timeout=180)
        assert built.returncode==0,built.stdout+built.stderr
        for harts in ('1','4','4'):
            out=subprocess.run([exe],env={**os.environ,'FPR_HARTS':harts},capture_output=True,text=True,timeout=30)
            assert out.returncode==0 and expect in out.stdout,(name,out.stdout,out.stderr)
        print(f'Owned watcher {name}: one/four harts, cleanup and subscriptions PASS')
