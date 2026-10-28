#!/usr/bin/env python3
"""Raw-byte pipelines: backpressure, owned jobs, limits and publication."""
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()


def lit(value):
    return json.dumps(str(value), ensure_ascii=False).replace('{', '\\{').replace('}', '\\}')


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix='sol-pipeline-') as tmp:
        w = Path(tmp).resolve()
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
        env |= {'SOL_GPU': '0', 'SOL_JIT': os.environ.get('FPR_TEST_JIT', '1'), 'SOL_CACHE_DIR': str(w / 'cache')}
        helper = w / 'worker.py'
        helper.write_text('''import os, signal, sys, time
mode=sys.argv[1]
if mode=="produce":
    for i in range(64):
        os.write(1,bytes(range(256))*1024)
        os.write(2,b"e"*8192)
elif mode=="relay":
    while True:
        data=os.read(0,65536)
        if not data: break
        os.write(2,b"r"*1024)
        sys.stdout.buffer.write(data)
elif mode=="early":
    os.read(0,1)
elif mode=="code":
    sys.exit(int(sys.argv[2]))
elif mode=="args":
    os.write(1,"|".join(sys.argv[2:]).encode())
elif mode=="bytes":
    os.write(1,bytes(range(256)))
elif mode=="overflow":
    os.write(int(sys.argv[2]),b"x"*1048577)
elif mode=="env":
    os.write(1,(os.getcwd()+"|"+os.environ["SOL_PIPELINE_VALUE"]).encode())
elif mode in ["hang","flood"]:
    child=os.fork()
    if child: open(sys.argv[2],"w").write(str(os.getpid())+"\\n"+str(child))
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    while True:
        with open(sys.argv[2]+(".child" if not child else ".parent"),"a") as f: f.write("x")
        if mode=="flood" and child: os.write(1,b"x"*8192)
        time.sleep(.02)
''')

        def stage(mode, *args):
            argv = ','.join(map(lit, [sys.executable, helper, mode, *args]))
            return f'ProcessSpec [{argv}] "" [] "" 0'

        def spec(stages, inp='PipeBytes (Bytes.empty Unit)', out='PipeCapture 1024', err='PipeCapture 1024', ms=3000, policy='PipeFail'):
            return f'PipelineSpec [{",".join(stages)}] ({inp}) ({out}) ({err}) {ms} {policy}'

        def run(name, source, expected=b'', code=0, error=None, stdin=None, descriptors=None):
            nonlocal count
            path = w / (name + '.sol')
            path.write_text('must r = case r of Ok value -> value | Err e -> error (str e).\n' + source)
            def limited():
                _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (descriptors, hard))
            p = subprocess.run([str(FPR), 'sol', str(path)], input=stdin, capture_output=True,
                               env=env, timeout=20, preexec_fn=limited if descriptors else None)
            assert (p.returncode, p.stdout) == (code, expected), (name, p)
            if error is not None:
                assert error in p.stderr, (name, p)
            count += 1
            return p

        inspect = 'showResult r = case r of Ok (PipelineResult code stages bytes errors) -> print (code,stages,Bytes.toList bytes,List.map Bytes.len errors) | Err e -> print e.\n'
        raw = bytes(range(256))
        run('binary_result', inspect + f'> showResult (Proc.pipeline ({spec([stage("bytes")])})).\n',
            f'(0, [0], {list(raw)}, [0])\n'.encode())
        run('raw_argv', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("args", "", "a b", ";$(echo no)*")])})); IO.stdout b.\n',
            b'|a b|;$(echo no)*')
        source = w / 'input.bin'
        source.write_bytes(raw * 4096)
        copied = w / 'copy.bin'
        run('file_source_and_sink', f'> print (isOk (Proc.pipeline ({spec([stage("relay")], inp=f"PipeFile {lit(source)}", out=f"PipeFileNew {lit(copied)}", err="PipeDiscard")}))).\n', b'True\n')
        assert copied.read_bytes() == source.read_bytes()
        script_copy = w / 'script-copy.bin'
        p = subprocess.run([str(FPR),'sol',str(ROOT/'sol/scripts/copy-pipeline.sol'),str(source),str(script_copy)],
                           env=env,cwd=w,capture_output=True,timeout=15)
        assert p.returncode == 0 and p.stdout == b'pipeline copy complete\n' and script_copy.read_bytes() == source.read_bytes(), p
        count += 1
        # 16 MiB, both channels larger than pipe buffers, connected through
        # bounded relay workers and a staged destination.
        dest = w / 'published.bin'
        run('backpressure_both_channels', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("produce"),stage("relay")], out=f"PipePublish {lit(dest)} False", err="PipeCapture 8388608", ms=10000)})); print (c,s,Bytes.len b,List.all (fn b -> Bytes.len b > 65536) e).\n',
            b'(0, [0, 0], 0, True)\n')
        assert dest.read_bytes() == raw * 65536

        run('early_consumer', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("produce"),stage("early")], out="PipeDiscard", err="PipeDiscard")})); print (c != 0,List.len s,List.last s).\n', b'(True, 2, 0)\n')
        for policy, status in [('PipeLast',3),('PipeFail',3)]:
            run('statuses_'+policy, f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("code",7),stage("code",3)], policy=policy)})); print (c,s).\n', f'({status}, [7, 3])\n'.encode())
        for policy, status in [('PipeLast',0),('PipeFail',7)]:
            run('policy_'+policy, f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("code",7),stage("code",0)], policy=policy)})); print c.\n', f'{status}\n'.encode())
        run('capture_overflow', inspect + f'> showResult (Proc.pipeline ({spec([stage("bytes")], out="PipeCapture 255")})).\n',
            b'ProcessError capture overflow 1 stdout 255\n')
        run('capture_exact', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("bytes")], out="PipeCapture 256")})); print (Bytes.len b).\n', b'256\n')
        run('stderr_overflow', inspect + f'> showResult (Proc.pipeline ({spec([stage("overflow",2)], err="PipeCapture 4096")})).\n',
            b'ProcessError capture overflow 1 stderr 4096\n')
        run('combined_capture_budget', f'> print (isOk (Proc.pipeline ({spec([stage("bytes")]*3, out="PipeCapture 16777216", err="PipeCapture 16777216")}))).\n', b'False\n')
        # The bounded text compatibility API must never decode arbitrary bytes
        # with the locale or collect unlimited output.
        run('text_capture_overflow', f'> print (Proc.query ({stage("overflow",1)})).\n',
            b'Err process ' + (' '.join(map(lambda x: json.dumps(str(x)), [sys.executable,helper,'overflow',1])) + ': capture overflow (stage 1, stdout, limit 1048576)\n').encode())
        run('text_capture_invalid_utf8', f'> print (isOk (Proc.query ({stage("bytes")}))).\n', b'False\n')
        # A failed deferred capture is saved as a failure and fences following
        # commands, while queued files reach their declared post-images.
        deferred_file = w / 'deferred-file'
        skipped = w / 'skipped-command'
        follower = f'ProcessSpec ["/bin/sh","-c",{lit("echo wrong > " + str(skipped))}] "" [] "" 0'
        run('deferred_capture_failure', f'> u = writePath {lit(deferred_file)} "committed";'
            f' a = Proc.afterCommit ({stage("overflow",1)}); Proc.afterCommit ({follower}).\n',
            code=1, error=b'capture overflow')
        assert deferred_file.read_text() == 'committed' and not skipped.exists()
        run('shell_capture_failure', '> shq "head -c 1048577 /dev/zero".\n', code=1, error=b'capture overflow')
        # PATH and relative cwd are chosen from each stage's effective values.
        bindir = w / 'bin'; bindir.mkdir()
        command = bindir / 'emit'
        command.write_text('#!/bin/sh\nprintf found'); command.chmod(0o755)
        pathstage = f'ProcessSpec ["emit"] {lit(w)} [("PATH",{lit(bindir)})] "" 0'
        run('stage_path', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([pathstage])})); IO.stdout b.\n', b'found')
        envstage = stage('env').replace('"" [] "" 0', f'{lit(bindir)} [("SOL_PIPELINE_VALUE","value")] "" 0')
        run('stage_cwd_env', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([envstage])})); IO.stdout b.\n', (str(bindir)+'|value').encode())
        run('inherited_input', f'> PipelineResult c s b e = must (Proc.pipeline ({spec([stage("relay")],inp="PipeInputInherit")})); IO.stdout b.\n', raw, stdin=raw)
        run('spawn_failure', f'> print (isOk (Proc.pipeline ({spec(["ProcessSpec [\"/no-such-sol-program\"] \"\" [] \"\" 0"])}))).\n', b'False\n')
        run('pending_fence', f'> u = writePath {lit(w / "queued")} "x"; print (isOk (Proc.pipeline ({spec([stage("bytes")])}))).\n', b'False\n')
        failed = w / 'failed-stage'
        run('failed_publication', f'> r = Proc.pipeline ({spec([stage("code",7)], out=f"PipePublish {lit(failed)} False")}); print (isOk r).\n', b'True\n')
        assert not failed.exists()
        existing = w / 'existing'
        existing.write_bytes(b'old'); existing.chmod(0o640)
        run('no_clobber', f'> print (isOk (Proc.pipeline ({spec([stage("bytes")], out=f"PipePublish {lit(existing)} False")}))).\n', b'False\n')
        assert existing.read_bytes() == b'old'
        run('replace_publish', f'> print (isOk (Proc.pipeline ({spec([stage("bytes")], out=f"PipePublish {lit(existing)} True")}))).\n', b'True\n')
        assert existing.read_bytes() == raw and existing.stat().st_mode & 0o777 == 0o640
        # A consumed job returns all the same byte results. Poll retains the
        # linear owner; cancel and wait consume it.
        run('owned_wait', f'> j = must (Proc.start ({spec([stage("bytes")])})); (p,j2) = Proc.poll j; PipelineResult c s b e = must (Proc.wait j2); IO.stdout b.\n', raw)
        run('forged_job', '> Proc.wait (ProcessJob 1).\n', code=1, error=b'expected an opaque process job')
        run('duplicated_job', f'> j = must (Proc.start ({spec([stage("bytes")])})); a = Proc.wait j; Proc.wait j.\n', code=1, error=b'linear')

        def stopped(pidfile):
            # Both descendants' heartbeat files stop changing. The leader is
            # directly reaped; the group boundary covers its forked child.
            files = [Path(str(pidfile)+suffix) for suffix in ['.parent','.child']]
            sizes = [p.stat().st_size if p.exists() else 0 for p in files]
            time.sleep(.15)
            assert sizes == [p.stat().st_size if p.exists() else 0 for p in files], pidfile

        for operation in ['timeout', 'cancel', 'boundary']:
            pidfile = w / (operation + '.pid')
            pipeline = spec([stage('hang',pidfile)], out='PipeDiscard', err='PipeDiscard', ms=200 if operation=='timeout' else 0)
            if operation=='timeout':
                run(operation, inspect + f'> showResult (Proc.pipeline ({pipeline})).\n', b'ProcessError timeout 0  200\n')
            elif operation=='cancel':
                run(operation, f'> j = must (Proc.start ({pipeline})); u = sleepMs 200; print (Proc.cancel j).\n', b'Ok ()\n')
            else:
                # Script.exit bypasses syntactic consumption; runtime sweep
                # still terminates/reaps the job before committing files.
                run(operation, f'> j = must (Proc.start ({pipeline})); u = sleepMs 200; stop = Script.exit 0; Proc.wait j.\n')
            assert pidfile.exists(), (operation, 'worker did not start')
            stopped(pidfile)
        pidfile = w / 'overflow.pid'
        run('overflow_descendants', inspect + f'> showResult (Proc.pipeline ({spec([stage("flood",pidfile)],out="PipeCapture 4096",err="PipeDiscard")})).\n',
            b'ProcessError capture overflow 1 stdout 4096\n')
        assert pidfile.exists()
        stopped(pidfile)
        # Ctrl-C must unwind the same owner tree and retain the runner's 130
        # status. A staged sink remains unpublished and leaves no scratch file.
        pidfile = w / 'interrupt.pid'
        interrupted_target = w / 'interrupted-target'
        interrupted_target.write_bytes(b'old')
        path = w / 'interrupt.sol'
        path.write_text(f'> Proc.pipeline ({spec([stage("hang",pidfile)],out=f"PipePublish {lit(interrupted_target)} True",err="PipeDiscard",ms=10000)}).\n')
        p = subprocess.Popen([str(FPR),'sol',str(path)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            end = time.monotonic()+5
            while not pidfile.exists() and time.monotonic()<end:
                time.sleep(.01)
            assert pidfile.exists(), 'interrupt worker did not start'
            p.send_signal(signal.SIGINT)
            out,err = p.communicate(timeout=5)
            assert p.returncode == 130 and b'interrupted' in err, (p.returncode,out,err)
        finally:
            if p.poll() is None:
                p.kill(); p.communicate()
        stopped(pidfile)
        assert interrupted_target.read_bytes() == b'old'
        count += 1
        run('repeated_descriptors', 'one n _ = r = Proc.pipeline (' + spec([stage('bytes')],out='PipeDiscard',err='PipeDiscard') + '); n + (if isOk r then 1 else 0).\n> print (List.fold one 0 (List.range 1 40)).\n', b'40\n', descriptors=96)
        assert not list(w.glob('.sol-pipe-*')), 'staging files leaked'
    print(f'sol pipeline checks: {count} passed')


if __name__ == '__main__':
    main()
